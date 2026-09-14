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

exception Sink_failed
exception Close_failed
exception Write_failed

let wire = function
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
  if mode = Normal || mode = Sink_error || mode = Upgrade then
    check "explicit graceful stop observed once"
      (List.length
         (List.filter
            (function O.Shutdown_started _ -> true | _ -> false)
            events)
      = 1);
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
    else check "response written" (written > 0))

let eio mode =
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
        | O.Connection_closed _ -> close_seen := !closes :: !close_seen
        | _ -> ());
        if mode = Sink_error then raise Sink_failed;
        if mode = Sink_cancel then
          match event with
          | O.Connection_accepted _ -> raise (Eio.Cancel.Cancelled Sink_failed)
          | _ -> ()
      in
      (try
         App.serve ~max_connections:1 ~observe ~clock ~stop
           ~random:(fun n -> String.make n 'x')
           ~accept:(fun () ->
             if !accepted then Eio.Fiber.await_cancel ();
             accepted := true;
             (transport, "private peer"))
           ~on_error:(fun _ -> stop_once ())
           (fun request ->
             handled := true;
             if mode = Upgrade then
               App.websocket ~allowed_origins:[ "https://example.test" ] request
                 (fun transport _ ->
                   let rec loop off =
                     if off < 7 then
                       loop (off + transport.write "upgrade" off (7 - off))
                   in
                   loop 0)
             else App.reply (Httpkit.Reply.text "ok"))
       with Eio.Cancel.Cancelled _ when mode = Sink_cancel -> ());
      check "close event follows actual close" (!close_seen = [ 1 ]);
      if mode = Normal || mode = Sink_error || mode = Upgrade then
        check "response body or upgraded payload completed"
          (String.ends_with
             ~suffix:(if mode = Upgrade then "upgrade" else "ok")
             (Buffer.contents output));
      verify mode !events !read !written !closes !handled)

let lwt mode =
  let open Lwt.Infix in
  let module App = Httpkit_lwt in
  let module A = Httpkit_transport_lwt in
  let stop, finish = Lwt.wait () in
  let stopped = ref false and accepted = ref false and handled = ref false in
  let read = ref 0 and written = ref 0 and closes = ref 0 and events = ref [] in
  let close_seen = ref [] and output = Buffer.create 256 in
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
    | O.Connection_closed _ -> close_seen := !closes :: !close_seen
    | _ -> ());
    if mode = Sink_error then raise Sink_failed;
    if mode = Sink_cancel then
      match event with O.Connection_accepted _ -> raise Lwt.Canceled | _ -> ()
  in
  Lwt.catch
    (fun () ->
      App.serve ~max_connections:1 ~observe ~clock:A.monotonic_clock ~stop
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
          Lwt.return
            (if mode = Upgrade then
               App.websocket ~allowed_origins:[ "https://example.test" ] request
                 (fun transport _ ->
                   let rec loop off =
                     if off = 7 then Lwt.return_unit
                     else
                       transport.write "upgrade" off (7 - off) >>= fun n ->
                       loop (off + n)
                   in
                   loop 0)
             else App.reply (Httpkit.Reply.text "ok"))))
    (function
      | Lwt.Canceled when mode = Sink_cancel -> Lwt.return_unit
      | exn -> Lwt.fail exn)
  >|= fun () ->
  check "close event follows actual close" (!close_seen = [ 1 ]);
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
    ]
  in
  List.iter eio modes;
  Lwt_main.run (Lwt_unix.with_timeout 5. (fun () -> Lwt_list.iter_s lwt modes));
  print_endline
    "PASS private connection observations preserve I/O and close ownership"
