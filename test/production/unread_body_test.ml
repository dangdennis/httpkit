module O = Httpkit.Observation

let check label condition = if not condition then failwith label

type case = Fixed | Trailers | Malformed | Quota | Partial_quota | Stalled

let name = function
  | Fixed -> "fixed"
  | Trailers -> "trailers"
  | Malformed -> "malformed"
  | Quota -> "quota"
  | Partial_quota -> "partial-quota"
  | Stalled -> "stalled"

let wire case =
  let head = "POST /first HTTP/1.1\r\nHost: x\r\n" in
  let body =
    match case with
    | Trailers ->
        head
        ^ "Transfer-Encoding: chunked\r\n\
           Trailer: x-note\r\n\
           \r\n\
           1\r\n\
           x\r\n\
           0\r\n\
           x-note: done\r\n\
           \r\n"
    | Malformed ->
        head ^ "Transfer-Encoding: chunked\r\n\r\n1\r\nx!\r\n0\r\n\r\n"
    | Stalled -> head ^ "Content-Length: 3\r\n\r\nx"
    | _ -> head ^ "Content-Length: 3\r\n\r\nabc"
  in
  if case = Stalled then body
  else body ^ "GET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

let verify case consume handled events closed =
  check "single transport closure" (closed = 1);
  check "correct dispatch boundary"
    (handled = if consume && (case = Fixed || case = Trailers) then 2 else 1);
  let failures =
    List.filter_map
      (function
        | O.Connection_failed { failure; _ } -> Some failure
        | Request_finished { outcome = Failed failure; _ } -> Some failure
        | _ -> None)
      events
  in
  if not consume then
    check "early response aborts upload without a spurious failure"
      (failures = [])
  else
    match case with
    | Fixed | Trailers ->
        check "valid consumed body has no failure" (failures = [])
    | Malformed ->
        check "consumed body validates framing"
          (List.mem O.Protocol_error failures)
    | Quota | Partial_quota ->
        check "body reads share application quota"
          (List.mem O.Resource_limit failures);
        check "body rejection observed once"
          (List.length
             (List.filter
                (function O.Body_limit_rejected _ -> true | _ -> false)
                events)
          = 1)
    | Stalled ->
        check "application deadline covers body reads with body idle disabled"
          (List.mem (O.Timeout O.Application) failures)

let policy = Result.get_ok (Httpkit_engine.Timeout.policy ~body_idle:None ())
let limit = function Quota | Partial_quota -> 2 | _ -> 1048576

let eio case consume step =
  let module App = Httpkit_eio in
  let module A = Httpkit_transport_eio in
  Eio_mock.Backend.run_full (fun env ->
      let stop, wake = Eio.Promise.create () in
      let accepted = ref false
      and stopped = ref false
      and pos = ref 0
      and closed = ref 0
      and handled = ref 0
      and events = ref [] in
      let observe event =
        events := event :: !events;
        match event with
        | O.Connection_closed _ when not !stopped ->
            stopped := true;
            Eio.Promise.resolve wake ()
        | _ -> ()
      in
      let input = wire case in
      let transport : A.transport =
        {
          read =
            (fun bytes off len ->
              if !pos = String.length input then Eio.Fiber.await_cancel ();
              let n = min step (min len (String.length input - !pos)) in
              Bytes.blit_string input !pos bytes off n;
              pos := !pos + n;
              n);
          write = (fun _ _ len -> min 7 len);
          close = (fun () -> incr closed);
        }
      in
      App.serve ~max_connections:1 ~body_limit:(limit case) ~policy
        ~request_timeout:2.
        ~clock:(Eio.Stdenv.mono_clock env)
        ~stop ~observe
        ~random:(fun n -> String.make n 'x')
        ~on_error:(fun exn -> prerr_endline (Printexc.to_string exn))
        ~accept:(fun () ->
          if !accepted then Eio.Fiber.await_cancel ();
          accepted := true;
          (transport, "test"))
        (fun request ->
          incr handled;
          if consume then (
            if case = Partial_quota && !handled = 1 then
              ignore (App.read request);
            ignore (App.body request));
          App.reply (Httpkit.Reply.text "ok"));
      verify case consume !handled !events !closed)

let lwt case consume step =
  let open Lwt.Infix in
  let module App = Httpkit_lwt in
  let module A = Httpkit_transport_lwt in
  let stop, wake = Lwt.wait () in
  let accepted = ref false
  and stopped = ref false
  and pos = ref 0
  and closed = ref 0
  and handled = ref 0
  and events = ref [] in
  let observe event =
    events := event :: !events;
    match event with
    | O.Connection_closed _ when not !stopped ->
        stopped := true;
        Lwt.wakeup_later wake ()
    | _ -> ()
  in
  let input = wire case in
  let transport : A.transport =
    {
      read =
        (fun bytes off len ->
          if !pos = String.length input then fst (Lwt.task ())
          else
            let n = min step (min len (String.length input - !pos)) in
            Bytes.blit_string input !pos bytes off n;
            pos := !pos + n;
            Lwt.return n);
      write = (fun _ _ len -> Lwt.return (min 7 len));
      close =
        (fun () ->
          incr closed;
          Lwt.return_unit);
    }
  in
  Lwt_main.run
    (Lwt_unix.with_timeout 1. (fun () ->
         App.serve ~max_connections:1 ~body_limit:(limit case) ~policy
           ~request_timeout:0.02 ~clock:A.monotonic_clock ~stop ~observe
           ~random:(fun n -> String.make n 'x')
           ~on_error:(fun exn ->
             prerr_endline (Printexc.to_string exn);
             Lwt.return_unit)
           ~accept:(fun () ->
             if !accepted then fst (Lwt.task ())
             else (
               accepted := true;
               Lwt.return (transport, "test")))
           (fun request ->
             incr handled;
             (if consume then
                (if case = Partial_quota && !handled = 1 then
                   App.read request >|= ignore
                 else Lwt.return_unit)
                >>= fun () -> App.body request >|= ignore
              else Lwt.return_unit)
             >|= fun () -> App.reply (Httpkit.Reply.text "ok"))));
  verify case consume !handled !events !closed

let () =
  Alcotest.run "Unread request body ownership"
    (List.map
       (fun (runtime, run) ->
         ( runtime,
           List.concat_map
             (fun (case, consume) ->
               List.map
                 (fun step ->
                   Alcotest.test_case
                     ((if consume then "consume/" else "ignore/")
                     ^ name case ^ "/" ^ string_of_int step)
                     `Quick
                     (fun () -> run case consume step))
                 [ 1; 7; 16384 ])
             (List.map
                (fun c -> (c, true))
                [ Fixed; Trailers; Malformed; Quota; Partial_quota; Stalled ]
             @ List.map
                 (fun c -> (c, false))
                 [ Fixed; Trailers; Malformed; Quota; Stalled ]) ))
       [ ("eio", eio); ("lwt", lwt) ])
