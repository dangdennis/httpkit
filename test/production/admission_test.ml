let check name condition = if not condition then failwith name
let wire = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"

exception Write_failed

let check_events observed events capacity =
  let module O = Httpkit.Observation in
  let active = ref 0 and accepted = ref [] and closed = ref [] in
  List.iter
    (function
      | O.Connection_accepted x ->
          incr active;
          accepted := x.connection :: !accepted;
          check "observed admission bound"
            (!active <= capacity && x.active_connections = !active)
      | O.Connection_closed x ->
          decr active;
          closed := x.connection :: !closed;
          check "observed close count and outcome"
            (x.active_connections = !active
            && !active >= 0 && x.close_status = O.Closed)
      | O.Shutdown_started _ ->
          failwith "external cancellation is not graceful stop")
    events;
  check "observed scopes all retired" (!active = 0);
  let ids = if observed then List.init (capacity + 1) Int64.of_int else [] in
  check "observed every admitted scope once"
    (List.sort Int64.compare !accepted = ids
    && List.sort Int64.compare !closed = ids)

let eio observed capacity =
  let module App = Httpkit_eio in
  let module A = Httpkit_transport_eio in
  Eio_mock.Backend.run_full (fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let stop, _ = Eio.Promise.create () in
      let admitted, all_admitted = Eio.Promise.create () in
      let writing, write_started = Eio.Promise.create () in
      let fail, fail_write = Eio.Promise.create () in
      let cleaning, cleanup_started = Eio.Promise.create () in
      let release, release_cleanup = Eio.Promise.create () in
      let replacement, replaced = Eio.Promise.create () in
      let accepted = ref 0 and cleaned = ref false and errors = ref 0 in
      let events = ref [] in
      let observe =
        if observed then Some (fun event -> events := !events @ [ event ])
        else None
      in
      let released = ref false in
      let release_once () =
        if not !released then (
          released := true;
          Eio.Promise.resolve release_cleanup ())
      in
      let closes = Array.make (capacity + 1) 0 in
      let accept () =
        let index = !accepted in
        check "Eio bounded acceptance" (index <= capacity);
        incr accepted;
        if !accepted = capacity then Eio.Promise.resolve all_admitted ();
        if index = capacity then Eio.Promise.resolve replaced ();
        let sent = ref false in
        let transport : A.transport =
          {
            read =
              (fun bytes off _ ->
                if !sent || index = capacity then Eio.Fiber.await_cancel ();
                sent := true;
                Bytes.blit_string wire 0 bytes off (String.length wire);
                String.length wire);
            write =
              (fun _ _ _ ->
                check "Eio only failing stream writes" (index = 0);
                Eio.Promise.resolve write_started ();
                Eio.Promise.await fail;
                raise Write_failed);
            close =
              (fun () ->
                if index = 0 then
                  check "Eio close follows producer cleanup" !cleaned;
                closes.(index) <- closes.(index) + 1);
          }
        in
        (transport, string_of_int index)
      in
      Eio.Fiber.first
        (fun () ->
          App.serve ?observe ~max_connections:capacity ~output_limit:1024 ~clock
            ~stop
            ~random:(fun n -> String.make n 'x')
            ~accept
            ~on_error:(fun exn ->
              let rec expected = function
                | A.Error (A.Transport Write_failed) -> true
                | Eio.Exn.Multiple errors ->
                    errors <> []
                    && List.for_all (fun (e, _) -> expected e) errors
                | _ -> false
              in
              check "Eio reports injected write failure" (expected exn);
              incr errors;
              check "Eio error follows close" (closes.(0) = 1))
            (fun request ->
              if App.peer request <> "0" then Eio.Fiber.await_cancel ();
              App.stream (fun send ->
                  Fun.protect
                    ~finally:(fun () ->
                      Eio.Cancel.protect (fun () ->
                          Eio.Promise.resolve cleanup_started ();
                          Eio.Promise.await release;
                          cleaned := true))
                    (fun () -> send (String.make 4096 'x')))))
        (fun () ->
          Fun.protect ~finally:release_once (fun () ->
              Eio.Promise.await admitted;
              Eio.Promise.await writing;
              Eio.Promise.resolve fail_write ();
              Eio.Promise.await cleaning;
              for _ = 1 to 8 do
                Eio.Fiber.yield ()
              done;
              check "Eio cleanup retains admission slot" (!accepted = capacity);
              check "Eio cleanup precedes close/report"
                (closes.(0) = 0 && !errors = 0);
              release_once ();
              Eio.Promise.await replacement;
              check "Eio exactly one slot is recycled" (!accepted = capacity + 1);
              check "Eio recycled slot is retired"
                (!cleaned && closes.(0) = 1 && !errors = 1)));
      check "Eio every admitted transport closes once"
        (Array.for_all (( = ) 1) closes);
      check_events observed !events capacity)

let lwt observed capacity =
  let open Lwt.Infix in
  let module App = Httpkit_lwt in
  let module A = Httpkit_transport_lwt in
  let stop, _ = Lwt.wait () in
  let admitted, all_admitted = Lwt.wait () in
  let writing, write_started = Lwt.wait () in
  let fail, fail_write = Lwt.wait () in
  let cleaning, cleanup_started = Lwt.wait () in
  let release, release_cleanup = Lwt.wait () in
  let replacement, replaced = Lwt.wait () in
  let accepted = ref 0 and cleaned = ref false and errors = ref 0 in
  let events = ref [] in
  let observe =
    if observed then Some (fun event -> events := !events @ [ event ]) else None
  in
  let closes = Array.make (capacity + 1) 0 in
  let accept () =
    let index = !accepted in
    check "Lwt bounded acceptance" (index <= capacity);
    incr accepted;
    if !accepted = capacity then Lwt.wakeup_later all_admitted ();
    if index = capacity then Lwt.wakeup_later replaced ();
    let sent = ref false in
    let transport : A.transport =
      {
        read =
          (fun bytes off _ ->
            if !sent || index = capacity then fst (Lwt.task ())
            else (
              sent := true;
              Bytes.blit_string wire 0 bytes off (String.length wire);
              Lwt.return (String.length wire)));
        write =
          (fun _ _ _ ->
            check "Lwt only failing stream writes" (index = 0);
            Lwt.wakeup_later write_started ();
            fail >>= fun () -> Lwt.fail Write_failed);
        close =
          (fun () ->
            if index = 0 then
              check "Lwt close follows producer cleanup" !cleaned;
            closes.(index) <- closes.(index) + 1;
            Lwt.return_unit);
      }
    in
    Lwt.return (transport, string_of_int index)
  in
  let server =
    App.serve ?observe ~max_connections:capacity ~output_limit:1024
      ~clock:A.monotonic_clock ~stop
      ~random:(fun n -> String.make n 'x')
      ~accept
      ~on_error:(fun exn ->
        check "Lwt reports injected write failure"
          (match exn with
          | A.Error (A.Transport Write_failed) -> true
          | _ -> false);
        incr errors;
        check "Lwt error follows close" (closes.(0) = 1);
        Lwt.return_unit)
      (fun request ->
        if App.peer request <> "0" then fst (Lwt.task ())
        else
          Lwt.return
            (App.stream (fun send ->
                 Lwt.finalize
                   (fun () -> send (String.make 4096 'x'))
                   (fun () ->
                     Lwt.no_cancel
                       (Lwt.wakeup_later cleanup_started ();
                        release >|= fun () -> cleaned := true)))))
  in
  Lwt.finalize
    (fun () ->
      admitted >>= fun () ->
      writing >>= fun () ->
      Lwt.wakeup_later fail_write ();
      cleaning >>= fun () ->
      let rec yield n =
        if n = 0 then Lwt.return_unit
        else Lwt.pause () >>= fun () -> yield (n - 1)
      in
      yield 8 >>= fun () ->
      check "Lwt cleanup retains admission slot" (!accepted = capacity);
      check "Lwt cleanup precedes close/report" (closes.(0) = 0 && !errors = 0);
      Lwt.wakeup_later release_cleanup ();
      replacement >|= fun () ->
      check "Lwt exactly one slot is recycled" (!accepted = capacity + 1);
      check "Lwt recycled slot is retired"
        (!cleaned && closes.(0) = 1 && !errors = 1))
    (fun () ->
      if Lwt.is_sleeping release then Lwt.wakeup_later release_cleanup ();
      Lwt.cancel server;
      Lwt.catch
        (fun () -> server)
        (function Lwt.Canceled -> Lwt.return_unit | exn -> Lwt.fail exn))
  >|= fun () ->
  check "Lwt every admitted transport closes once"
    (Array.for_all (( = ) 1) closes);
  check_events observed !events capacity

let () =
  List.iter (fun observed -> List.iter (eio observed) [ 1; 3 ]) [ false; true ];
  Lwt_main.run
    (Lwt_unix.with_timeout 5. (fun () ->
         Lwt_list.iter_s
           (fun observed -> Lwt_list.iter_s (lwt observed) [ 1; 3 ])
           [ false; true ]));
  print_endline "PASS application admission waits for failed producer cleanup"
