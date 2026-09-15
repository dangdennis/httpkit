let check label condition = if not condition then failwith label
let wire = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

let progress events =
  List.filter_map
    (function
      | Httpkit.Observation.Shutdown_progress x -> Some x.active_connections
      | _ -> None)
    events

let shutdown_observed events =
  List.mem Httpkit.Observation.Shutdown_finished events

let eio observed =
  let module App = Httpkit_eio in
  let module A = Httpkit_transport_eio in
  Eio_mock.Backend.run_full (fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let stop, stop_server = Eio.Promise.create () in
      let handling, handler_started = Eio.Promise.create () in
      let response, finish_handler = Eio.Promise.create () in
      let late, accept_late = Eio.Promise.create () in
      let closing, close_started = Eio.Promise.create () in
      let release, finish_close = Eio.Promise.create () in
      let retired, active_closed = Eio.Promise.create () in
      let finished, server_finished = Eio.Promise.create () in
      let accepted = ref 0 and stopping = ref false and done_ = ref false in
      let close_complete = ref false
      and close_cancelled = ref false
      and released = ref false in
      let closes = Array.make 2 0 in
      let events = ref [] in
      let release_once () =
        if not !released then (
          released := true;
          Eio.Promise.resolve finish_close ())
      in
      let observe =
        if observed then
          Some
            (fun event ->
              events := !events @ [ event ];
              match event with
              | Httpkit.Observation.Shutdown_started _ -> stopping := true
              | _ -> ())
        else None
      in
      let accept () =
        let index = !accepted in
        check "Eio no third acceptance" (index < 2);
        incr accepted;
        if index = 1 then Eio.Promise.await late;
        let sent = ref false in
        let transport : A.transport =
          {
            read =
              (fun bytes off _ ->
                check "Eio late transport never enters driver" (index = 0);
                if !sent then Eio.Fiber.await_cancel ();
                sent := true;
                Bytes.blit_string wire 0 bytes off (String.length wire);
                String.length wire);
            write = (fun _ _ n -> n);
            close =
              (fun () ->
                closes.(index) <- closes.(index) + 1;
                if index = 0 then Eio.Promise.resolve active_closed ()
                else (
                  Eio.Promise.resolve close_started ();
                  Fun.protect
                    ~finally:(fun () ->
                      if not !close_complete then close_cancelled := true)
                    (fun () ->
                      Eio.Promise.await release;
                      close_complete := true)));
          }
        in
        (transport, "test")
      in
      Eio.Fiber.both
        (fun () ->
          Fun.protect
            ~finally:(fun () ->
              done_ := true;
              Eio.Promise.resolve server_finished ())
            (fun () ->
              App.serve ?observe ~max_connections:2 ~clock ~stop ~accept
                ~random:(fun n -> String.make n 'x')
                ~on_error:raise
                (fun _ ->
                  Eio.Promise.resolve handler_started ();
                  Eio.Promise.await response;
                  App.reply (Httpkit.Reply.text "ok"))))
        (fun () ->
          Fun.protect ~finally:release_once (fun () ->
              Eio.Promise.await handling;
              Eio.Promise.resolve stop_server ();
              for _ = 1 to 8 do
                Eio.Fiber.yield ()
              done;
              if observed then
                check "Eio stop observed before late accept" !stopping;
              Eio.Promise.resolve accept_late ();
              Eio.Promise.await closing;
              Eio.Promise.resolve finish_handler ();
              Eio.Promise.await retired;
              for _ = 1 to 16 do
                Eio.Fiber.yield ()
              done;
              check "Eio shutdown must join late close"
                ((not !done_) && (not !close_cancelled) && not !close_complete);
              check "no premature Eio shutdown-finished observation"
                (not (shutdown_observed !events));
              release_once ();
              Eio.Promise.await finished));
      check "Eio close operations completed exactly once"
        (!close_complete && closes = [| 1; 1 |]);
      if observed then (
        check "Eio progress counts late accepted ownership"
          (progress !events = [ 1; 2; 1; 0 ]);
        check "Eio shutdown completion observed after close"
          (shutdown_observed !events)))

let lwt observed =
  let open Lwt.Infix in
  let module App = Httpkit_lwt in
  let module A = Httpkit_transport_lwt in
  let stop, stop_server = Lwt.wait () in
  let handling, handler_started = Lwt.wait () in
  let response, finish_handler = Lwt.wait () in
  let late, accept_late = Lwt.wait () in
  let closing, close_started = Lwt.wait () in
  let release, finish_close = Lwt.task () in
  let retired, active_closed = Lwt.wait () in
  let accepted = ref 0 and stopping = ref false and done_ = ref false in
  let close_complete = ref false and close_cancelled = ref false in
  let closes = Array.make 2 0 in
  let events = ref [] in
  let release_once () =
    if Lwt.is_sleeping release then Lwt.wakeup_later finish_close ()
  in
  let observe =
    if observed then
      Some
        (fun event ->
          events := !events @ [ event ];
          match event with
          | Httpkit.Observation.Shutdown_started _ -> stopping := true
          | _ -> ())
    else None
  in
  let accept () =
    let index = !accepted in
    check "Lwt no third acceptance" (index < 2);
    incr accepted;
    (if index = 1 then late else Lwt.return_unit) >|= fun () ->
    let sent = ref false in
    let transport : A.transport =
      {
        read =
          (fun bytes off _ ->
            check "Lwt late transport never enters driver" (index = 0);
            if !sent then fst (Lwt.task ())
            else (
              sent := true;
              Bytes.blit_string wire 0 bytes off (String.length wire);
              Lwt.return (String.length wire)));
        write = (fun _ _ n -> Lwt.return n);
        close =
          (fun () ->
            closes.(index) <- closes.(index) + 1;
            if index = 0 then (
              Lwt.wakeup_later active_closed ();
              Lwt.return_unit)
            else (
              Lwt.wakeup_later close_started ();
              Lwt.finalize
                (fun () -> release >|= fun () -> close_complete := true)
                (fun () ->
                  if not !close_complete then close_cancelled := true;
                  Lwt.return_unit)));
      }
    in
    (transport, "test")
  in
  let server =
    Lwt.finalize
      (fun () ->
        App.serve ?observe ~max_connections:2 ~clock:A.monotonic_clock ~stop
          ~accept
          ~random:(fun n -> String.make n 'x')
          ~on_error:Lwt.fail
          (fun _ ->
            Lwt.wakeup_later handler_started ();
            response >|= fun () -> App.reply (Httpkit.Reply.text "ok")))
      (fun () ->
        done_ := true;
        Lwt.return_unit)
  in
  let rec yield n =
    if n = 0 then Lwt.return_unit else Lwt.pause () >>= fun () -> yield (n - 1)
  in
  Lwt.finalize
    (fun () ->
      handling >>= fun () ->
      Lwt.wakeup_later stop_server ();
      yield 8 >>= fun () ->
      if observed then check "Lwt stop observed before late accept" !stopping;
      Lwt.wakeup_later accept_late ();
      closing >>= fun () ->
      Lwt.wakeup_later finish_handler ();
      retired >>= fun () ->
      yield 16 >>= fun () ->
      check "Lwt shutdown must join late close"
        ((not !done_) && (not !close_cancelled) && not !close_complete);
      check "no premature Lwt shutdown-finished observation"
        (not (shutdown_observed !events));
      release_once ();
      server >|= fun () ->
      check "Lwt close operations completed exactly once"
        (!close_complete && closes = [| 1; 1 |]);
      if observed then (
        check "Lwt progress counts late accepted ownership"
          (progress !events = [ 1; 2; 1; 0 ]);
        check "Lwt shutdown completion observed after close"
          (shutdown_observed !events)))
    (fun () ->
      release_once ();
      Lwt.cancel server;
      Lwt.catch
        (fun () -> server)
        (function Lwt.Canceled -> Lwt.return_unit | exn -> Lwt.fail exn))

let () =
  let failures = ref [] in
  let report name exn =
    let error = name ^ ": " ^ Printexc.to_string exn in
    prerr_endline error;
    failures := error :: !failures
  in
  List.iter
    (fun observed ->
      try eio observed
      with exn -> report ("Eio observe=" ^ string_of_bool observed) exn)
    [ false; true ];
  Lwt_main.run
    (Lwt_unix.with_timeout 5. (fun () ->
         Lwt_list.iter_s
           (fun observed ->
             Lwt.catch
               (fun () -> lwt observed)
               (fun exn ->
                 report ("Lwt observe=" ^ string_of_bool observed) exn;
                 Lwt.return_unit))
           [ false; true ]));
  check "late accept shutdown regression" (!failures = []);
  print_endline "PASS shutdown joins close of late accepted transports"
