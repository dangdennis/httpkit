open Adapter_fixtures
open Lwt.Syntax
module A = Http_kit_lwt
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
          Lwt.return n);
      write =
        (fun src off len ->
          let n = min 3 len in
          Buffer.add_substring output src off n;
          Lwt.return n);
      close =
        (fun () ->
          incr closed;
          Lwt.return_unit);
    }
  in
  (transport, closed, output)

let serve c body =
  let* event = A.next_event c in
  let id = match event with E.Request (id, _) -> id | _ -> assert false in
  let* event = A.next_event c in
  assert (event = E.Complete id);
  let* () = A.respond c id (response (String.length body)) in
  let* () = A.send c id body in
  A.finish c id

let partial () =
  Lwt_main.run
    (Lwt_list.iter_s
       (fun fragment ->
         let t, closed, out = mock ~fragment get in
         let* () =
           A.with_connection t (ok (E.server ())) (fun c -> serve c "abc")
         in
         assert (!closed = 1);
         assert (Buffer.contents out = wire "abc");
         Lwt.return_unit)
       [ 1; 2; 16384 ])

let error () =
  Lwt_main.run
    (Lwt_list.iter_s
       (fun failure ->
         let t, closed, _ = mock get in
         let t =
           {
             t with
             write =
               (fun _ _ _ ->
                 if failure then Lwt.fail_with "write failure" else Lwt.return 0);
           }
         in
         let* () =
           Lwt.catch
             (fun () ->
               let* () =
                 A.with_connection t (ok (E.server ())) (fun c -> serve c "abc")
               in
               assert false)
             (function
               | A.Error (A.Transport _) -> Lwt.return_unit
               | exn -> Lwt.fail exn)
         in
         assert (!closed = 1);
         Lwt.return_unit)
       [ false; true ])

let handler_error () =
  Lwt_main.run
    (Lwt_list.iter_s (fun close_fails ->
       let t, closed, _ = mock get in
       let t = if close_fails then
         { t with close = (fun () -> let* () = t.close () in Lwt.fail_with "close") }
         else t in
       let* () = Lwt.catch
         (fun () ->
           let* () = A.with_connection t (ok (E.server ())) (fun _ -> Lwt.fail Exit) in
           Lwt.fail_with "handler exception was swallowed")
         (function Exit -> Lwt.return_unit | exn -> Lwt.fail exn) in
       assert (!closed = 1);
       Lwt.return_unit) [false; true])

let cancel_read () =
  Lwt_main.run
    (let started, resolver = Lwt.task () and active = ref 0 in
     let t, closed, _ = mock "" in
     let t =
       {
         t with
         read =
           (fun _ _ _ ->
             incr active;
             Lwt.wakeup_later resolver ();
             Lwt.finalize
               (fun () -> fst (Lwt.task ()))
               (fun () ->
                 decr active;
                 Lwt.return_unit));
       }
     in
     let work =
       A.with_connection t
         (ok (E.server ()))
         (fun c ->
           let* _ = A.next_event c in
           Lwt.return_unit)
     in
     let* () = started in
     Lwt.cancel work;
     let* () =
       Lwt.catch
         (fun () ->
           let* () = work in
           assert false)
         (function Lwt.Canceled -> Lwt.return_unit | exn -> Lwt.fail exn)
     in
     assert (!active = 0);
     assert (!closed = 1);
     Lwt.return_unit)

let handoff () =
  Lwt_main.run
    (Lwt_list.iter_s
       (fun claim ->
         let t, closed, _ = mock connect in
         let* transferred =
           A.with_connection t
             (ok (E.server ()))
             (fun c ->
               let* event = A.next_event c in
               let id =
                 match event with E.Request (id, _) -> id | _ -> assert false
               in
               let* event = A.next_event c in
               assert (event = E.Complete id);
               let* () = A.respond c id (tunnel ()) in
               let* event = A.next_event c in
               assert (event = E.Handoff id);
               if claim then (
                 let t, suffix = A.take_handoff c in
                 assert (suffix = "TLS");
                 Lwt.return (Some t))
               else Lwt.return_none)
         in
         match transferred with
         | None ->
             assert (!closed = 1);
             Lwt.return_unit
         | Some t ->
             assert (!closed = 0);
             let* () = t.close () in
             assert (!closed = 1);
             Lwt.return_unit)
       [ false; true ])

let sockets () =
  Lwt_main.run
    (let a, b = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let body = String.init 200000 (fun i -> Char.chr (97 + (i mod 26))) in
     let* (), () =
       Lwt.both
         (A.with_connection (A.of_fd a)
            (ok (E.server ()))
            (fun c -> serve c body))
         (A.with_connection (A.of_fd b)
            (ok (E.client ()))
            (fun c ->
              let* id = A.submit_request c (request ()) in
              let* () = A.finish c id in
              let* event = A.next_event c in
              (match event with
              | E.Response (i, _) -> assert (E.equal_id i id)
              | _ -> assert false);
              let out = Buffer.create 64 in
              let rec read () =
                let* event = A.next_event c in
                match event with
                | E.Data (i, s) ->
                    assert (E.equal_id i id);
                    Buffer.add_string out s;
                    read ()
                | E.Complete i ->
                    assert (E.equal_id i id);
                    Lwt.return_unit
                | _ -> assert false
              in
              let* () = read () in
              assert (Buffer.contents out = body);
              Lwt.return_unit))
     in
     Lwt.return_unit)

let cancel_write () =
  Lwt_main.run
    (Lwt_list.iter_s
       (fun schedule ->
         let started, resolver = Lwt.task () and active = ref 0 in
         let t, closed, _ = mock ~fragment:(1 + (schedule mod 31)) get in
         let t =
           {
             t with
             write =
               (fun _ _ _ ->
                 incr active;
                 Lwt.wakeup_later resolver ();
                 Lwt.finalize
                   (fun () -> fst (Lwt.task ()))
                   (fun () ->
                     decr active;
                     Lwt.return_unit));
           }
         in
         let work =
           A.with_connection t
             (ok (E.server ~output_limit:128 ()))
             (fun c -> serve c (String.make 10000 'x'))
         in
         let* () = started in
         let rec pause n =
           if n = 0 then Lwt.return_unit
           else
             let* () = Lwt.pause () in
             pause (n - 1)
         in
         let* () = pause (schedule mod 4) in
         Lwt.cancel work;
         let* () =
           Lwt.catch
             (fun () ->
               let* () = work in
               assert false)
             (function Lwt.Canceled -> Lwt.return_unit | exn -> Lwt.fail exn)
         in
         assert (!closed = 1 && !active = 0);
         Lwt.return_unit)
       (List.init 100 Fun.id))

let collection () =
  Lwt_main.run
    (Lwt_list.iter_s
       (fun limit ->
         let input =
           "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
         in
         let t, closed, _ = mock ~fragment:1 input in
         let* () =
           Lwt.catch
             (fun () ->
               A.with_connection t
                 (ok (E.server ()))
                 (fun c ->
                   let* event = A.next_event c in
                   let id =
                     match event with
                     | E.Request (id, _) -> id
                     | _ -> assert false
                   in
                   let* body, trailers = A.collect_body ~limit c id in
                   assert (
                     limit >= 3 && body = "abc"
                     && Http_kit_core.Headers.length trailers = 0);
                   Lwt.return_unit))
             (function
               | A.Error (A.Engine E.Resource_limit) ->
                   assert (limit < 3);
                   Lwt.return_unit
               | exn -> Lwt.fail exn)
         in
         assert (!closed = 1);
         Lwt.return_unit)
       [ 0; 2; 3; 4 ])

let admission () =
  Lwt_main.run
    (let admitted, resolver = Lwt.task ()
     and accepted = ref 0
     and closed = ref 0 in
     let accept () =
       incr accepted;
       if !accepted = 2 then Lwt.wakeup_later resolver ();
       Lwt.return
         {
           A.read = (fun _ _ _ -> fst (Lwt.task ()));
           write = (fun _ _ n -> Lwt.return n);
           close =
             (fun () ->
               incr closed;
               Lwt.return_unit);
         }
     in
     let server =
       A.serve_connections ~max_connections:2 ~accept ~on_error:Lwt.fail
         (fun _ -> fst (Lwt.task ()))
     in
     let* () = admitted in
     let* () = Lwt.pause () in
     assert (!accepted = 2);
     Lwt.cancel server;
     let* () =
       Lwt.catch
         (fun () -> server)
         (function Lwt.Canceled -> Lwt.return_unit | exn -> Lwt.fail exn)
     in
     assert (!accepted = 2 && !closed = 2);
     Lwt.return_unit)

let header_timeout () =
  Lwt_main.run
    (let now = ref 0. and timers = ref [] in
     let clock : A.clock =
       {
         now = (fun () -> !now);
         sleep =
           (fun delay ->
             let p, r = Lwt.task () in
             timers := (!now +. delay, p, r) :: !timers;
             p);
       }
     in
     let advance n =
       now := n;
       let due, later = List.partition (fun (at, _, _) -> at <= n) !timers in
       timers := later;
       List.iter
         (fun (_, p, r) -> if Lwt.is_sleeping p then Lwt.wakeup_later r ())
         due
     in
     let reads = ref [] in
     let t, closed, _ = mock "" in
     let t =
       {
         t with
         read =
           (fun b o _ ->
             let p, r = Lwt.task () in
             reads := (b, o, p, r) :: !reads;
             p);
       }
     in
     let work =
       A.with_connection ~clock t
         (ok (E.server ()))
         (fun c ->
           let* _ = A.next_event c in
           Lwt.return_unit)
     in
     let rec tick n =
       if n > 14 || not (Lwt.is_sleeping work) then Lwt.return_unit
       else (
         advance (float n);
         (* Timers win equal-time readiness in this deterministic schedule. *)
         let* () = Lwt.pause () in
         (match !reads with
         | (b, o, p, r) :: tail when Lwt.is_sleeping p ->
             reads := tail;
             Bytes.set b o 'G';
             Lwt.wakeup_later r 1
         | _ -> ());
         let* () = Lwt.pause () in
         tick (n + 2))
     in
     let* () = tick 2 in
     let* () =
       Lwt.catch
         (fun () ->
           let* () = work in
           assert false)
         (function
           | A.Error (A.Timeout A.Timeout.Head) -> Lwt.return_unit
           | exn -> Lwt.fail exn)
     in
     assert (!now <= 14. && !closed = 1);
     assert (List.for_all (fun (_, p, _) -> not (Lwt.is_sleeping p)) !timers);
     assert (List.for_all (fun (_, _, p, _) -> not (Lwt.is_sleeping p)) !reads);
     Lwt.return_unit)

let other_deadlines () =
  Lwt_main.run
    (Lwt_list.iter_s
       (fun phase ->
         let now = ref 0. and timers = ref [] in
         let clock : A.clock =
           {
             now = (fun () -> !now);
             sleep =
               (fun delay ->
                 let p, r = Lwt.task () in
                 timers := (!now +. delay, p, r) :: !timers;
                 p);
           }
         in
         let t, closed, _ =
           mock "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n"
         in
         let first = ref true in
         let t =
           {
             t with
             read =
               (fun b o l ->
                 if !first && (phase = A.Timeout.Body || phase = A.Timeout.Write)
                 then (
                   first := false;
                   t.read b o l)
                 else fst (Lwt.task ()));
             write =
               (fun s o l ->
                 if phase = A.Timeout.Write then fst (Lwt.task ())
                 else t.write s o l);
           }
         in
         let engine =
           ok (if phase = A.Timeout.Shutdown then E.client () else E.server ())
         in
         let work =
           A.with_connection
             ~policy:(ok (A.Timeout.policy ~header:100. ()))
             ~clock t engine
             (fun c ->
               if phase = A.Timeout.Shutdown then
                 let* id = A.submit_request c (request ()) in
                 let* () = A.finish c id in
                 A.shutdown c
               else if phase = A.Timeout.Idle then
                 let* _ = A.next_event c in
                 Lwt.return_unit
               else
                 let* event = A.next_event c in
                 let id =
                   match event with
                   | E.Request (id, _) -> id
                   | _ -> assert false
                 in
                 if phase = A.Timeout.Write then
                   let* () = A.respond c id (response 3) in
                   let* () = A.send c id "abc" in
                   A.finish c id
                 else
                   let* _ = A.collect_body c id in
                   Lwt.return_unit)
         in
         let rec pump budget =
           let* () = Lwt.pause () in
           if not (Lwt.is_sleeping work) then Lwt.return_unit
           else (
             assert (budget > 0);
             match List.filter (fun (_, p, _) -> Lwt.is_sleeping p) !timers with
             | [] -> pump (budget - 1)
             | pending ->
                 let deadline =
                   List.fold_left
                     (fun acc (at, _, _) -> min acc at)
                     infinity pending
                 in
                 now := deadline;
                 List.iter
                   (fun (at, p, r) ->
                     if at <= deadline && Lwt.is_sleeping p then
                       Lwt.wakeup_later r ())
                   pending;
                 pump (budget - 1))
         in
         let* () = pump 100 in
         let* () =
           Lwt.catch
             (fun () ->
               let* () = work in
               assert false)
             (function
               | A.Error (A.Timeout actual) ->
                   assert (actual = phase);
                   Lwt.return_unit
               | exn -> Lwt.fail exn)
         in
         assert (!closed = 1);
         assert (List.for_all (fun (_, p, _) -> not (Lwt.is_sleeping p)) !timers);
         Lwt.return_unit)
       [ A.Timeout.Idle; A.Timeout.Body; A.Timeout.Write; A.Timeout.Shutdown ])

let read_failures () =
  Lwt_main.run
    (Lwt_list.iter_s
       (fun kind ->
         let t, closed, _ =
           mock "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na"
         in
         let t =
           if kind = `Transport_exception then
             { t with read = (fun _ _ _ -> Lwt.fail_with "read") }
           else if kind = `Invalid_count then
             { t with read = (fun _ _ _ -> Lwt.return (-1)) }
           else t
         in
         let* () =
           Lwt.catch
             (fun () ->
               let* () =
                 A.with_connection t
                   (ok (E.server ()))
                   (fun c ->
                     let* event = A.next_event c in
                     let id =
                       match event with
                       | E.Request (id, _) -> id
                       | _ -> assert false
                     in
                     let* _ = A.collect_body c id in
                     Lwt.return_unit)
               in
               assert false)
             (function
               | A.Error failure ->
                   (match kind, failure with
                    | `Transport_exception, A.Transport (Failure message) -> assert (message = "read")
                    | `Invalid_count, A.Transport (Invalid_argument message) -> assert (message = "transport read count")
                    | `Truncated_body, A.Engine (E.Protocol Http_kit_http1.Unexpected_eof) -> ()
                    | _ -> Alcotest.fail "wrong read failure category");
                   Lwt.return_unit
               | exn -> Lwt.fail exn)
         in
         assert (!closed = 1);
         Lwt.return_unit)
       [ `Transport_exception; `Invalid_count; `Truncated_body ])

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
  Alcotest.run "native Lwt"
    [
      ( "lifecycle",
        List.map
          (fun (n, f) -> bounded n f)
          [
            ("fragmented reads and partial writes", partial);
            ("write failure cannot become successful flush", error);
            ("handler cleanup", handler_error);
            ("cancel and join read", cancel_read);
            ("handoff residual and close ownership", handoff);
            ("real socket streaming", sockets);
            ("read failure, invalid read and premature EOF", read_failures);
            ("body, write, idle and graceful deadlines", other_deadlines);
            ("100 write/admission cancellation schedules", cancel_write);
            ("bounded collection", collection);
            ("connection admission cleanup", admission);
            ( "controlled absolute header timeout and timer cleanup",
              header_timeout );
          ] );
    ]
