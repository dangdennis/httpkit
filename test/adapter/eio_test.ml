open Adapter_fixtures
module A = Http_kit_eio
module E = Http_kit_engine

let mock ?(fragment = 16384) input =
  let offset = ref 0 and closed = ref 0 and output = Buffer.create 64 in
  let transport : A.transport =
    {
      read =
        (fun dst off len ->
          let n = min fragment (min len (String.length input - !offset)) in
          Bytes.blit_string input !offset dst off n;
          offset := !offset + n;
          n);
      write =
        (fun src off len ->
          let n = min 3 len in
          Buffer.add_substring output src off n;
          n);
      close = (fun () -> incr closed);
    }
  in
  (transport, closed, output)

let serve c body =
  let id =
    match A.next_event c with E.Request (id, _) -> id | _ -> assert false
  in
  assert (A.next_event c = E.Complete id);
  A.respond c id (response (String.length body));
  A.send c id body;
  A.finish c id

let run f = Eio_mock.Backend.run_full (fun env -> f (Eio.Stdenv.mono_clock env))

let partial () =
  run (fun clock ->
      List.iter
        (fun fragment ->
          let t, closed, out = mock ~fragment get in
          A.with_connection ~clock t (ok (E.server ())) (fun c -> serve c "abc");
          assert (!closed = 1);
          assert (Buffer.contents out = wire "abc"))
        [ 1; 2; 16384 ])

let error () =
  run (fun clock ->
      List.iter
        (fun failure ->
          let t, closed, _ = mock get in
          let t =
            {
              t with
              write =
                (fun _ _ _ -> if failure then failwith "write failure" else 0);
            }
          in
          (try
             A.with_connection ~clock t
               (ok (E.server ()))
               (fun c -> serve c "abc");
             assert false
           with A.Error (A.Transport _) -> ());
          assert (!closed = 1))
        [ false; true ])

let handler_error () =
  run (fun clock ->
      let t, closed, _ = mock get in
      List.iter
        (fun close_fails ->
          let t =
            if close_fails then
              {
                t with
                close =
                  (fun () ->
                    t.close ();
                    failwith "close");
              }
            else t
          in
          try
            A.with_connection ~clock t
              (ok (E.server ()))
              (fun _ -> (raise Exit : unit));
            Alcotest.fail "handler exception was swallowed"
          with Exit -> ())
        [ false; true ];
      assert (!closed = 2))

let cancel_read () =
  run (fun clock ->
      let started, resolver = Eio.Promise.create () and active = ref 0 in
      let t, closed, _ = mock "" in
      let t =
        {
          t with
          read =
            (fun _ _ _ ->
              incr active;
              Eio.Promise.resolve resolver ();
              Fun.protect
                ~finally:(fun () -> decr active)
                Eio.Fiber.await_cancel);
        }
      in
      (try
         Eio.Fiber.first
           (fun () ->
             A.with_connection ~clock t
               (ok (E.server ()))
               (fun c -> ignore (A.next_event c)))
           (fun () ->
             Eio.Promise.await started;
             raise Exit)
       with Exit -> ());
      assert (!active = 0);
      assert (!closed = 1))

let header_timeout () =
  run (fun clock ->
      let t, closed, _ = mock ~fragment:1 get in
      let reads = ref 0 in
      let t =
        {
          t with
          read =
            (fun b o l ->
              incr reads;
              Eio.Time.Mono.sleep clock 2.;
              t.read b o l);
        }
      in
      (try
         A.with_connection ~clock t
           (ok (E.server ()))
           (fun c -> ignore (A.next_event c));
         assert false
       with A.Error (A.Timeout A.Timeout.Head) -> ());
      assert (!closed = 1);
      assert (!reads <= 7))

let handoff () =
  run (fun clock ->
      List.iter
        (fun claim ->
          let t, closed, _ = mock connect in
          let transferred =
            A.with_connection ~clock t
              (ok (E.server ()))
              (fun c ->
                let id =
                  match A.next_event c with
                  | E.Request (id, _) -> id
                  | _ -> assert false
                in
                assert (A.next_event c = E.Complete id);
                A.respond c id (tunnel ());
                assert (A.next_event c = E.Handoff id);
                if claim then (
                  let t, suffix = A.take_handoff c in
                  assert (suffix = "TLS");
                  Some t)
                else None)
          in
          match transferred with
          | None -> assert (!closed = 1)
          | Some t ->
              assert (!closed = 0);
              t.close ();
              assert (!closed = 1))
        [ false; true ])

let sockets () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let a, b = Eio_unix.Net.socketpair_stream ~sw () in
          let body = String.init 200000 (fun i -> Char.chr (97 + (i mod 26))) in
          Eio.Fiber.both
            (fun () ->
              A.with_connection
                ~clock:(Eio.Stdenv.mono_clock env)
                (A.of_flow a)
                (ok (E.server ()))
                (fun c -> serve c body))
            (fun () ->
              A.with_connection
                ~clock:(Eio.Stdenv.mono_clock env)
                (A.of_flow b)
                (ok (E.client ()))
                (fun c ->
                  let id = A.submit_request c (request ()) in
                  A.finish c id;
                  (match A.next_event c with
                  | E.Response (i, _) -> assert (E.equal_id i id)
                  | _ -> assert false);
                  let out = Buffer.create 64 in
                  let rec read () =
                    match A.next_event c with
                    | E.Data (i, s) ->
                        assert (E.equal_id i id);
                        Buffer.add_string out s;
                        read ()
                    | E.Complete i -> assert (E.equal_id i id)
                    | _ -> assert false
                  in
                  read ();
                  assert (Buffer.contents out = body)))))

let cancel_write () =
  run (fun clock ->
      for schedule = 0 to 99 do
        let started, resolver = Eio.Promise.create () and active = ref 0 in
        let t, closed, _ = mock ~fragment:(1 + (schedule mod 31)) get in
        let t =
          {
            t with
            write =
              (fun _ _ _ ->
                incr active;
                Eio.Promise.resolve resolver ();
                Fun.protect
                  ~finally:(fun () -> decr active)
                  Eio.Fiber.await_cancel);
          }
        in
        (try
           Eio.Fiber.first
             (fun () ->
               A.with_connection ~clock t
                 (ok (E.server ~output_limit:128 ()))
                 (fun c -> serve c (String.make 10000 'x')))
             (fun () ->
               Eio.Promise.await started;
               for _ = 0 to schedule mod 4 do
                 Eio.Fiber.yield ()
               done;
               raise Exit)
         with Exit -> ());
        assert (!closed = 1 && !active = 0)
      done)

let collection () =
  run (fun clock ->
      List.iter
        (fun limit ->
          let input =
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
          in
          let t, closed, _ = mock ~fragment:1 input in
          (try
             A.with_connection ~clock t
               (ok (E.server ()))
               (fun c ->
                 let id =
                   match A.next_event c with
                   | E.Request (id, _) -> id
                   | _ -> assert false
                 in
                 let body, trailers = A.collect_body ~limit c id in
                 assert (
                   limit >= 3 && body = "abc"
                   && Http_kit_core.Headers.length trailers = 0))
           with A.Error (A.Engine E.Resource_limit) -> assert (limit < 3));
          assert (!closed = 1))
        [ 0; 2; 3; 4 ])

let admission () =
  run (fun clock ->
      let admitted, resolver = Eio.Promise.create ()
      and accepted = ref 0
      and closed = ref 0 in
      let accept () =
        incr accepted;
        if !accepted = 2 then Eio.Promise.resolve resolver ();
        {
          A.read = (fun _ _ _ -> Eio.Fiber.await_cancel ());
          write = (fun _ _ n -> n);
          close = (fun () -> incr closed);
        }
      in
      (try
         Eio.Fiber.first
           (fun () ->
             A.serve_connections ~max_connections:2 ~clock ~accept
               ~on_error:raise (fun _ -> Eio.Fiber.await_cancel ()))
           (fun () ->
             Eio.Promise.await admitted;
             Eio.Fiber.yield ();
             assert (!accepted = 2);
             raise Exit)
       with Exit -> ());
      assert (!accepted = 2 && !closed = 2))

let idle_deadlines () =
  run (fun clock ->
      List.iter
        (fun phase ->
          let t, closed, _ = mock get in
          let t =
            match phase with
            | A.Timeout.Write ->
                { t with write = (fun _ _ _ -> Eio.Fiber.await_cancel ()) }
            | _ -> { t with read = (fun _ _ _ -> Eio.Fiber.await_cancel ()) }
          in
          (try
             A.with_connection ~clock t
               (ok (E.server ()))
               (fun c ->
                 if phase = A.Timeout.Write then serve c "abc"
                 else ignore (A.next_event c));
             assert false
           with A.Error (A.Timeout actual) -> assert (actual = phase));
          assert (!closed = 1))
        [ A.Timeout.Idle; A.Timeout.Write ])

let body_shutdown_deadlines () =
  run (fun clock ->
      List.iter
        (fun phase ->
          let t, closed, _ =
            mock "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n"
          in
          let first = ref true in
          let t =
            {
              t with
              read =
                (fun b o l ->
                  if !first && phase = A.Timeout.Body then (
                    first := false;
                    t.read b o l)
                  else Eio.Fiber.await_cancel ());
            }
          in
          let engine =
            ok (if phase = A.Timeout.Body then E.server () else E.client ())
          in
          (try
             A.with_connection ~clock t engine (fun c ->
                 if phase = A.Timeout.Body then
                   let id =
                     match A.next_event c with
                     | E.Request (id, _) -> id
                     | _ -> assert false
                   in
                   ignore (A.collect_body c id)
                 else
                   let id = A.submit_request c (request ()) in
                   A.finish c id;
                   A.shutdown c);
             assert false
           with A.Error (A.Timeout actual) -> assert (actual = phase));
          assert (!closed = 1))
        [ A.Timeout.Body; A.Timeout.Shutdown ])

let read_failures () =
  run (fun clock ->
      List.iter
        (fun kind ->
          let t, closed, _ =
            mock "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na"
          in
          let t =
            if kind = `Transport_exception then
              { t with read = (fun _ _ _ -> failwith "read") }
            else if kind = `Invalid_count then
              { t with read = (fun _ _ _ -> -1) }
            else t
          in
          (try
             A.with_connection ~clock t
               (ok (E.server ()))
               (fun c ->
                 let id =
                   match A.next_event c with
                   | E.Request (id, _) -> id
                   | _ -> assert false
                 in
                 ignore (A.collect_body c id));
             assert false
           with A.Error failure -> (
             match (kind, failure) with
             | `Transport_exception, A.Transport (Failure message) ->
                 assert (message = "read")
             | `Invalid_count, A.Transport (Invalid_argument message) ->
                 assert (message = "transport read count")
             | ( `Truncated_body,
                 A.Engine (E.Protocol Http_kit_http1.Unexpected_eof) ) ->
                 ()
             | _ -> Alcotest.fail "wrong read failure category"));
          assert (!closed = 1))
        [ `Transport_exception; `Invalid_count; `Truncated_body ])

let configured_admission () =
  run (fun clock ->
      let accepted = ref 0 and failures = ref 0 and closures = ref [] in
      let accept () =
        if !accepted = 2 then raise Exit;
        incr accepted;
        let transport, closed, _ = mock get in
        closures := closed :: !closures;
        transport
      in
      (try
         A.serve_connections ~max_connections:1 ~output_limit:16 ~clock ~accept
           ~on_error:(function
             | A.Error (A.Engine E.Resource_limit) -> incr failures
             | exn -> raise exn)
           (fun c ->
             let id =
               match A.next_event c with
               | E.Request (id, _) -> id
               | _ -> assert false
             in
             A.respond c id (response 3));
         Alcotest.fail "accept termination swallowed"
       with Exit -> ());
      assert (!failures = 2 && List.for_all (fun count -> !count = 1) !closures);
      let accepted = ref false in
      (try
         A.serve_connections ~output_limit:0 ~clock
           ~accept:(fun () ->
             accepted := true;
             raise Exit)
           ~on_error:raise
           (fun _ -> ());
         Alcotest.fail "invalid configuration accepted"
       with A.Error (A.Engine E.Resource_limit) -> ());
      assert (not !accepted);
      assert (
        A.failure_to_string (A.Engine E.Invalid_command)
        = "engine: invalid engine command"))

let bounded name f =
  Alcotest.test_case name `Quick (fun () ->
      match
        Harness_runtime.Watchdog.run ~seconds:10. (fun () ->
            try f ()
            with exn ->
              prerr_endline (Printexc.to_string exn);
              Printexc.print_backtrace stderr;
              raise exn)
      with
      | Exited 0 -> ()
      | _ -> Alcotest.fail "adapter child failed or hung")

let () =
  Alcotest.run "native Eio"
    [
      ( "lifecycle",
        List.map
          (fun (n, f) -> bounded n f)
          [
            ("fragmented reads and partial writes", partial);
            ("write failure cannot become successful flush", error);
            ("handler cleanup", handler_error);
            ("configured admission and diagnostics", configured_admission);
            ("cancel and join read", cancel_read);
            ("absolute header timeout", header_timeout);
            ("handoff residual and close ownership", handoff);
            ("real socket streaming", sockets);
            ("read failure, invalid read and premature EOF", read_failures);
            ("body, write, idle and graceful deadlines", body_shutdown_deadlines);
            ("100 write/admission cancellation schedules", cancel_write);
            ("bounded collection", collection);
            ("connection admission cleanup", admission);
            ("idle and write timeouts", idle_deadlines);
          ] );
    ]
