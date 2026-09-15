module O = Httpkit.Observation

let check message condition = if not condition then failwith message

type mode =
  | Normal
  | Sink_error
  | Sink_cancel
  | Close_failure
  | Write_failure
  | Invalid_write
  | Upgrade
  | Handler_error
  | Stream_error
  | Handler_timeout
  | Stream_timeout
  | Enqueued
  | Body_limit
  | Collection_limit

exception Sink_failed
exception Close_failed
exception Write_failed

let wire = function
  | Body_limit | Collection_limit ->
      "POST / HTTP/1.1\r\n\
       Host: private\r\n\
       Content-Length: 2\r\n\
       Connection: close\r\n\
       \r\n\
       xx"
  | Upgrade ->
      "GET /socket HTTP/1.1\r\n\
       Host: private\r\n\
       Connection: Upgrade\r\n\
       Upgrade: websocket\r\n\
       Sec-WebSocket-Version: 13\r\n\
       Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
       Origin: https://example.test\r\n\
       \r\n"
  | _ ->
      "GET /?secret=query HTTP/1.1\r\n\
       Host: private\r\n\
       Authorization: secret\r\n\
       Cookie: secret\r\n\
       Connection: close\r\n\
       \r\n"

let verify mode events read written closes handled =
  check "transport closes once" (closes = 1);
  let opened =
    List.filter_map
      (function
        | O.Connection_accepted x -> Some (x.connection, x.active_connections)
        | _ -> None)
      events
  in
  check "single connection acceptance" (opened = [ (0L, 1) ]);
  if mode <> Sink_cancel then
    check "saturation reports owned slots, not rejected connections"
      (List.filter_map
         (function
           | O.Admission_saturated x -> Some (x.active_connections, x.capacity)
           | _ -> None)
         events
      = [ (1, 1) ]);
  if mode = Normal || mode = Sink_error || mode = Upgrade then
    check "explicit graceful stop observed once"
      (List.length
         (List.filter
            (function O.Shutdown_started _ -> true | _ -> false)
            events)
      = 1);
  if mode = Normal || mode = Sink_error || mode = Upgrade then (
    check "shutdown scope finished once"
      (List.length (List.filter (( = ) O.Shutdown_finished) events) = 1);
    check "shutdown ended after scope retirement"
      (List.hd (List.rev events) = O.Shutdown_finished));
  let closed =
    List.filter (function O.Connection_closed _ -> true | _ -> false) events
  in
  (match closed with
  | [ O.Connection_closed x ] ->
      check "connection retired" (x.connection = 0L && x.active_connections = 0);
      check "read bytes count successful prefixes"
        (x.bytes_read = Int64.of_int read);
      check "write bytes count successful prefixes"
        (x.bytes_written = Int64.of_int written);
      check "monotonic duration available"
        (Option.fold ~none:false
           ~some:(fun d -> Float.is_finite d && d >= 0.)
           x.duration_seconds);
      check "close outcome is explicit"
        (x.close_status
        = if mode = Close_failure then O.Close_failed else O.Closed)
  | _ -> failwith "Missing or duplicate close event");
  if mode = Sink_cancel then
    check "sink cancellation is preserved before handler"
      ((not handled) && read = 0 && written = 0)
  else (
    check "handler ran" handled;
    check "request fully read" (read = String.length (wire mode));
    if mode = Invalid_write || mode = Write_failure then
      check "failed write not counted" (written = 0)
    else if
      not
        (List.mem mode
           [
             Stream_error;
             Handler_timeout;
             Stream_timeout;
             Body_limit;
             Collection_limit;
           ])
    then check "response written" (written > 0));
  let starts =
    List.filter_map
      (function
        | O.Request_started x -> Some (x.connection, x.request) | _ -> None)
      events
  in
  let finishes =
    List.filter_map
      (function
        | O.Request_finished x ->
            Some (x.connection, x.request, x.outcome, x.duration_seconds)
        | _ -> None)
      events
  in
  (match (starts, finishes) with
  | [], [] when mode = Sink_cancel -> ()
  | [ (c, r) ], [ (c', r', outcome, duration) ] -> (
      check "request scope identity" (c = 0L && c = c' && r = r');
      check "request duration"
        (Option.fold ~none:false ~some:(fun d -> d >= 0.) duration);
      match mode with
      | Handler_timeout | Stream_timeout ->
          check "application timeout category"
            (outcome = O.Failed (O.Timeout O.Application))
      | Stream_error ->
          check "stream failure category"
            (outcome = O.Failed O.Application_error)
      | Body_limit | Collection_limit ->
          check "body rejection remains a resource failure"
            (outcome = O.Failed O.Resource_limit)
      | Upgrade -> check "handoff outcome" (outcome = O.Upgraded)
      | Normal | Sink_error | Close_failure | Handler_error | Enqueued ->
          check "response enqueue outcome" (outcome = O.Response_enqueued)
      | _ -> ())
  | _ -> failwith "unbalanced request observations");
  let callbacks =
    List.filter_map
      (function
        | O.Callback_finished x -> Some (x.stage, x.failure) | _ -> None)
      events
  in
  (match mode with
  | Handler_error ->
      check "handler failure precedes recovery"
        (callbacks = [ (O.Handler, Some O.Application_error) ])
  | Body_limit | Collection_limit ->
      check "body rejection callback failure"
        (callbacks = [ (O.Handler, Some O.Resource_limit) ])
  | Stream_error ->
      check "stream failure observed separately"
        (callbacks
        = [ (O.Handler, None); (O.Response_stream, Some O.Application_error) ])
  | Handler_timeout ->
      check "handler cancellation observed"
        (callbacks = [ (O.Handler, Some O.Cancelled) ])
  | Stream_timeout ->
      check "stream cancellation observed"
        (callbacks
        = [ (O.Handler, None); (O.Response_stream, Some O.Cancelled) ])
  | Sink_cancel -> check "no callbacks before cancellation" (callbacks = [])
  | _ -> check "handler completion observed" (callbacks = [ (O.Handler, None) ]));
  let statuses =
    List.filter_map
      (function O.Response_headers_enqueued x -> Some x.status | _ -> None)
      events
  in
  let rejected =
    List.filter_map
      (function
        | O.Body_limit_rejected x -> Some (x.connection, x.request, x.limit)
        | _ -> None)
      events
  in
  (match (mode, starts) with
  | (Body_limit | Collection_limit), [ (connection, request) ] ->
      check "exact request body rejection identity/limit"
        (rejected = [ (connection, request, 1) ]);
      check "rejection does not invent a response" (statuses = [])
  | _ -> check "no spurious body rejection" (rejected = []));
  if mode = Handler_error then
    check "recovered status is 500" (statuses = [ 500 ]);
  if mode = Handler_timeout || mode = Sink_cancel then
    check "no response status before headers" (statuses = [])

let eio mode =
  let request_timeout =
    if mode = Handler_timeout || mode = Stream_timeout then 0.01 else 60.
  in
  let module App = Httpkit_eio in
  let module A = Httpkit_transport_eio in
  Eio_mock.Backend.run_full (fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let stop, finish = Eio.Promise.create () in
      let stopped = ref false
      and accepted = ref false
      and handled = ref false in
      let read = ref 0
      and written = ref 0
      and closes = ref 0
      and events = ref [] in
      let close_seen = ref [] and output = Buffer.create 256 in
      let gate, release = Eio.Promise.create () in
      let enqueued_before_write = ref false in
      let stop_once () =
        if not !stopped then (
          stopped := true;
          Eio.Promise.resolve finish ())
      in
      let input = wire mode in
      let transport : A.transport =
        {
          read =
            (fun bytes off length ->
              if !read = String.length input then Eio.Fiber.await_cancel ();
              let n = min 7 (min length (String.length input - !read)) in
              Bytes.blit_string input !read bytes off n;
              read := !read + n;
              n);
          write =
            (fun data off length ->
              if mode = Enqueued then Eio.Promise.await gate;
              if mode = Write_failure then raise Write_failed;
              if mode = Invalid_write then length + 1
              else
                let n = min 5 length in
                Buffer.add_substring output data off n;
                written := !written + n;
                n);
          close =
            (fun () ->
              incr closes;
              if mode = Close_failure then raise Close_failed;
              stop_once ());
        }
      in
      let observe event =
        events := !events @ [ event ];
        (match event with
        | O.Request_finished _ when mode = Enqueued ->
            enqueued_before_write := !written = 0;
            Eio.Promise.resolve release ()
        | _ -> ());
        (match event with
        | O.Connection_closed _ -> close_seen := !closes :: !close_seen
        | _ -> ());
        if mode = Sink_error then raise Sink_failed;
        if mode = Sink_cancel then
          match event with
          | O.Connection_accepted _ -> raise (Eio.Cancel.Cancelled Sink_failed)
          | _ -> ()
      in
      (try
         App.serve ~max_connections:1
           ~body_limit:(if mode = Body_limit then 1 else 1048576)
           ~request_timeout ~observe ~clock ~stop
           ~random:(fun n -> String.make n 'x')
           ~accept:(fun () ->
             if !accepted then Eio.Fiber.await_cancel ();
             accepted := true;
             (transport, "private peer"))
           ~on_error:(fun _ -> stop_once ())
           (fun request ->
             handled := true;
             if mode = Handler_error then raise Sink_failed;
             if mode = Handler_timeout then Eio.Fiber.await_cancel ();
             if mode = Body_limit || mode = Collection_limit then
               ignore
                 (App.body
                    ~limit:(if mode = Collection_limit then 1 else 3)
                    request);
             if mode = Upgrade then
               App.websocket ~allowed_origins:[ "https://example.test" ] request
                 (fun transport _ ->
                   let rec loop off =
                     if off < 7 then
                       loop (off + transport.write "upgrade" off (7 - off))
                   in
                   loop 0)
             else if mode = Stream_error then
               App.stream (fun _ -> raise Sink_failed)
             else if mode = Stream_timeout then
               App.stream (fun _ -> Eio.Fiber.await_cancel ())
             else App.reply (Httpkit.Reply.text "ok"))
       with Eio.Cancel.Cancelled _ when mode = Sink_cancel -> ());
      check "close event follows actual close" (!close_seen = [ 1 ]);
      if mode = Enqueued then
        check "enqueue does not wait for transport drain" !enqueued_before_write;
      if mode = Normal || mode = Sink_error || mode = Upgrade then
        check "response body or upgraded payload completed"
          (String.ends_with
             ~suffix:(if mode = Upgrade then "upgrade" else "ok")
             (Buffer.contents output));
      verify mode !events !read !written !closes !handled)

let lwt mode =
  let request_timeout =
    if mode = Handler_timeout || mode = Stream_timeout then 0.01 else 60.
  in
  let open Lwt.Infix in
  let module App = Httpkit_lwt in
  let module A = Httpkit_transport_lwt in
  let stop, finish = Lwt.wait () in
  let stopped = ref false and accepted = ref false and handled = ref false in
  let read = ref 0 and written = ref 0 and closes = ref 0 and events = ref [] in
  let close_seen = ref [] and output = Buffer.create 256 in
  let gate, release = Lwt.wait () in
  let enqueued_before_write = ref false in
  let stop_once () =
    if not !stopped then (
      stopped := true;
      Lwt.wakeup_later finish ())
  in
  let input = wire mode in
  let transport : A.transport =
    {
      read =
        (fun bytes off length ->
          if !read = String.length input then fst (Lwt.task ())
          else
            let n = min 7 (min length (String.length input - !read)) in
            Bytes.blit_string input !read bytes off n;
            read := !read + n;
            Lwt.return n);
      write =
        (fun data off length ->
          (if mode = Enqueued then gate else Lwt.return_unit) >>= fun () ->
          if mode = Write_failure then Lwt.fail Write_failed
          else if mode = Invalid_write then Lwt.return (length + 1)
          else
            let n = min 5 length in
            Buffer.add_substring output data off n;
            written := !written + n;
            Lwt.return n);
      close =
        (fun () ->
          incr closes;
          if mode = Close_failure then Lwt.fail Close_failed
          else (
            stop_once ();
            Lwt.return_unit));
    }
  in
  let observe event =
    events := !events @ [ event ];
    (match event with
    | O.Request_finished _ when mode = Enqueued ->
        enqueued_before_write := !written = 0;
        Lwt.wakeup_later release ()
    | _ -> ());
    (match event with
    | O.Connection_closed _ -> close_seen := !closes :: !close_seen
    | _ -> ());
    if mode = Sink_error then raise Sink_failed;
    if mode = Sink_cancel then
      match event with O.Connection_accepted _ -> raise Lwt.Canceled | _ -> ()
  in
  Lwt.catch
    (fun () ->
      App.serve ~max_connections:1
        ~body_limit:(if mode = Body_limit then 1 else 1048576)
        ~request_timeout ~observe ~clock:A.monotonic_clock ~stop
        ~random:(fun n -> String.make n 'x')
        ~accept:(fun () ->
          if !accepted then fst (Lwt.task ())
          else (
            accepted := true;
            Lwt.return (transport, "private peer")))
        ~on_error:(fun _ ->
          stop_once ();
          Lwt.return_unit)
        (fun request ->
          handled := true;
          if mode = Handler_error then Lwt.fail Sink_failed
          else if mode = Handler_timeout then fst (Lwt.task ())
          else if mode = Body_limit || mode = Collection_limit then
            App.body ~limit:(if mode = Collection_limit then 1 else 3) request
            >|= fun _ -> App.reply (Httpkit.Reply.text "unexpected")
          else
            Lwt.return
              (if mode = Upgrade then
                 App.websocket ~allowed_origins:[ "https://example.test" ]
                   request (fun transport _ ->
                     let rec loop off =
                       if off = 7 then Lwt.return_unit
                       else
                         transport.write "upgrade" off (7 - off) >>= fun n ->
                         loop (off + n)
                     in
                     loop 0)
               else if mode = Stream_error then
                 App.stream (fun _ -> Lwt.fail Sink_failed)
               else if mode = Stream_timeout then
                 App.stream (fun _ -> fst (Lwt.task ()))
               else App.reply (Httpkit.Reply.text "ok"))))
    (function
      | Lwt.Canceled when mode = Sink_cancel -> Lwt.return_unit
      | exn -> Lwt.fail exn)
  >|= fun () ->
  check "close event follows actual close" (!close_seen = [ 1 ]);
  if mode = Enqueued then
    check "enqueue does not wait for transport drain" !enqueued_before_write;
  if mode = Normal || mode = Sink_error || mode = Upgrade then
    check "response body or upgraded payload completed"
      (String.ends_with
         ~suffix:(if mode = Upgrade then "upgrade" else "ok")
         (Buffer.contents output));
  verify mode !events !read !written !closes !handled

let () =
  let modes =
    [
      Normal;
      Sink_error;
      Sink_cancel;
      Close_failure;
      Write_failure;
      Invalid_write;
      Upgrade;
      Handler_error;
      Stream_error;
      Handler_timeout;
      Stream_timeout;
      Enqueued;
      Body_limit;
      Collection_limit;
    ]
  in
  List.iter eio modes;
  Lwt_main.run (Lwt_unix.with_timeout 5. (fun () -> Lwt_list.iter_s lwt modes));
  print_endline
    "PASS private connection observations preserve I/O and close ownership"
