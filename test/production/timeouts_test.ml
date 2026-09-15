module T = Httpkit_engine.Timeout

let check message valid = if not valid then failwith message

let policy phase =
  let duration p = if p = phase then 2. else 100. in
  Result.get_ok
    (T.policy ~header:(duration T.Head)
       ~body_idle:(Some (duration T.Body))
       ~write_idle:(Some (duration T.Write))
       ~keep_alive:(duration T.Idle) ~graceful:(duration T.Shutdown) ())

let input = function
  | T.Idle -> ""
  | T.Head -> "G"
  | T.Body | T.Shutdown ->
      "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nx"
  | T.Write -> "GET / HTTP/1.1\r\nHost: x\r\n\r\n"

let phases = [ T.Idle; T.Head; T.Body; T.Write; T.Shutdown ]

let check_observed phase events =
  let module O = Httpkit.Observation in
  let expected =
    O.Timeout
      (match phase with
      | T.Idle -> O.Idle
      | Head -> O.Header
      | Body -> O.Body
      | Write -> O.Write
      | Shutdown -> O.Shutdown)
  in
  let failures =
    List.filter_map
      (function O.Connection_failed x -> Some x.failure | _ -> None)
      events
  in
  check "observed transport timeout category"
    (failures <> [] && List.for_all (( = ) expected) failures)

let eio phase =
  let module App = Httpkit_eio in
  let module A = Httpkit_transport_eio in
  Eio_mock.Backend.run_full (fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let start = Eio.Time.Mono.now clock in
      let stop, finish = Eio.Promise.create () in
      let stopped = ref false
      and accepted = ref false
      and delivered = ref false
      and closed = ref 0
      and failures = ref [] in
      let stop_once () =
        if not !stopped then (
          stopped := true;
          Eio.Promise.resolve finish ())
      in
      let wire = input phase in
      let observations = ref [] in
      let transport : A.transport =
        {
          read =
            (fun bytes off _ ->
              if !delivered || wire = "" then Eio.Fiber.await_cancel ();
              delivered := true;
              Bytes.blit_string wire 0 bytes off (String.length wire);
              String.length wire);
          write =
            (fun _ _ length ->
              if phase = T.Write then Eio.Fiber.await_cancel ();
              length);
          close = (fun () -> incr closed);
        }
      in
      App.serve
        ~observe:(fun event -> observations := event :: !observations)
        ~policy:(policy phase) ~max_connections:1 ~clock
        ~random:(fun n -> String.make n 'x')
        ~stop
        ~accept:(fun () ->
          if !accepted then Eio.Fiber.await_cancel ();
          accepted := true;
          (transport, "test"))
        ~on_error:(fun exn ->
          failures := exn :: !failures;
          stop_once ())
        (fun request ->
          if phase = T.Shutdown then (
            stop_once ();
            Eio.Fiber.await_cancel ());
          if phase = T.Body then ignore (App.body request);
          App.reply (Httpkit.Reply.text "ok"));
      let rec expected = function
        | A.Error (A.Timeout p) -> p = phase
        | Eio.Exn.Multiple errors ->
            errors <> [] && List.for_all (fun (exn, _) -> expected exn) errors
        | _ -> false
      in
      check
        ("Eio configured timeout phase: "
        ^ String.concat "; " (List.map Printexc.to_string !failures))
        (!failures <> [] && List.for_all expected !failures);
      check "Eio timeout closes once" (!closed = 1);
      check_observed phase !observations;
      let elapsed =
        Mtime.Span.to_float_ns (Mtime.span start (Eio.Time.Mono.now clock))
        /. 1e9
      in
      check "Eio custom deadline is effective" (abs_float (elapsed -. 2.) < 1e-6))

let lwt phase =
  let open Lwt.Infix in
  let module App = Httpkit_lwt in
  let module A = Httpkit_transport_lwt in
  let stopped, finish = Lwt.wait () in
  let registered, register = Lwt.wait () in
  let deadline, expire = Lwt.task () in
  let stopping = ref false
  and accepted = ref false
  and delivered = ref false
  and closed = ref 0
  and failures = ref []
  and now = ref 0. in
  let stop_once () =
    if not !stopping then (
      stopping := true;
      Lwt.wakeup_later finish ())
  in
  let clock : A.clock =
    {
      now = (fun () -> !now);
      sleep =
        (fun seconds ->
          if seconds = 2. then (
            Lwt.wakeup_later register ();
            deadline)
          else fst (Lwt.task ()));
    }
  in
  let wire = input phase in
  let observations = ref [] in
  let transport : A.transport =
    {
      read =
        (fun bytes off _ ->
          if !delivered || wire = "" then fst (Lwt.task ())
          else (
            delivered := true;
            Bytes.blit_string wire 0 bytes off (String.length wire);
            Lwt.return (String.length wire)));
      write =
        (fun _ _ length ->
          if phase = T.Write then fst (Lwt.task ()) else Lwt.return length);
      close =
        (fun () ->
          incr closed;
          Lwt.return_unit);
    }
  in
  let server =
    App.serve
      ~observe:(fun event -> observations := event :: !observations)
      ~policy:(policy phase) ~max_connections:1 ~clock
      ~random:(fun n -> String.make n 'x')
      ~stop:stopped
      ~accept:(fun () ->
        if !accepted then fst (Lwt.task ())
        else (
          accepted := true;
          Lwt.return (transport, "test")))
      ~on_error:(fun exn ->
        failures := exn :: !failures;
        stop_once ();
        Lwt.return_unit)
      (fun request ->
        (if phase = T.Shutdown then (
           stop_once ();
           fst (Lwt.task ()))
         else if phase = T.Body then App.body request >|= ignore
         else Lwt.return_unit)
        >|= fun () -> App.reply (Httpkit.Reply.text "ok"))
  in
  Lwt.finalize
    (fun () ->
      registered >>= fun () ->
      now := 2.;
      Lwt.wakeup_later expire ();
      server >|= fun () ->
      check "Lwt configured timeout phase"
        (!failures <> []
        && List.for_all
             (function A.Error (A.Timeout p) -> p = phase | _ -> false)
             !failures);
      check "Lwt timeout closes once" (!closed = 1);
      check_observed phase !observations)
    (fun () ->
      Lwt.cancel server;
      Lwt.catch (fun () -> server) (fun _ -> Lwt.return_unit))

let () =
  List.iter eio phases;
  Lwt_main.run (Lwt_unix.with_timeout 5. (fun () -> Lwt_list.iter_s lwt phases));
  print_endline "PASS application timeout policy reaches all Eio/Lwt phases"
