module C = Httpkit_client_eio
module F = Client_fixtures

let run ?(collision = false) ?(count = 3) ?(expire = false) ?(uploading = false)
    ?(server_close = false) tls abandon =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
          let listener =
            Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr listener with
            | `Tcp (_, p) -> p
            | _ -> assert false
          in
          (if collision then
             let other =
               Eio.Net.listen ~sw ~backlog:1 net
                 (`Tcp (Eio.Net.Ipaddr.V6.loopback, port))
             in
             Eio.Fiber.fork_daemon ~sw (fun () ->
                 let flow, _ = Eio.Net.accept ~sw other in
                 Eio.Flow.close flow;
                 `Stop_daemon));
          let origin =
            Printf.sprintf "%s://127.0.0.1:%d"
              (if tls then "https" else "http")
              port
          in
          let accepted = ref 0 and closed = ref 0 and escaped = ref None in
          Eio.Fiber.both
            (fun () ->
              for
                _ = 1 to if abandon || expire || server_close then count else 1
              do
                let raw, _ = Eio.Net.accept ~sw listener in
                incr accepted;
                let t =
                  if tls then
                    Httpkit_transport_eio.of_flow
                      (Tls_eio.server_of_flow (F.server ~ip:true ()) raw)
                  else Httpkit_transport_eio.of_flow raw
                in
                Fun.protect ~finally:t.close (fun () ->
                    let b = Bytes.create 1 in
                    let rec requests () =
                      let head = Buffer.create 100 in
                      let rec header () =
                        if
                          String.ends_with ~suffix:"\r\n\r\n"
                            (Buffer.contents head)
                        then true
                        else if t.read b 0 1 = 0 then false
                        else (
                          Buffer.add_char head (Bytes.get b 0);
                          header ())
                      in
                      if header () then (
                        assert (
                          String.starts_with
                            ~prefix:(if uploading then "POST / " else "GET / ")
                            (Buffer.contents head));
                        if uploading then
                          String.iter
                            (fun c ->
                              assert (t.read b 0 1 = 1 && Bytes.get b 0 = c))
                            "abc";
                        let response =
                          if server_close then
                            "HTTP/1.1 200 OK\r\n\
                             Connection: close\r\n\
                             Content-Length: 3\r\n\
                             \r\n\
                             abc"
                          else "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc"
                        in
                        let rec write off =
                          if off < String.length response then
                            write
                              (off
                              + t.write response off
                                  (String.length response - off))
                        in
                        write 0;
                        requests ())
                      else incr closed
                    in
                    requests ())
              done)
            (fun () ->
              C.with_pool ~net ~clock
                ~authenticator:(F.authenticator ~ip:true true)
                ~max_connections:1
                ~idle_timeout:(if expire then 0.000001 else 30.)
                origin
                (fun pool ->
                  escaped := Some pool;
                  (try
                     C.request pool "http://example.invalid/" (fun _ _ -> ());
                     assert false
                   with Invalid_argument _ -> ());
                  for _ = 1 to count do
                    let upload =
                      if uploading then
                        let sent = ref false in
                        Some
                          (C.upload ~length:3L (fun () ->
                               if !sent then None
                               else (
                                 sent := true;
                                 Some "abc")))
                      else None
                    in
                    C.request pool ?upload
                      ~meth:
                        (if uploading then Httpkit_core.Method.post
                         else Httpkit_core.Method.get)
                      (origin ^ "/")
                      (fun _ body ->
                        (try
                           C.request pool (origin ^ "/") (fun _ _ -> ());
                           assert false
                         with C.Pool_exhausted -> ());
                        if not abandon then
                          let rec read () =
                            match C.read body with
                            | None -> ()
                            | Some _ -> read ()
                          in
                          read ())
                  done));
          assert (
            (!accepted = if abandon || expire || server_close then count else 1)
            && !closed = !accepted);
          try
            C.request (Option.get !escaped) (origin ^ "/") (fun _ _ -> ());
            assert false
          with Invalid_argument _ -> ()))

let scope_cancellation () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
          let listener =
            Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr listener with
            | `Tcp (_, p) -> p
            | _ -> assert false
          in
          let origin = Printf.sprintf "http://127.0.0.1:%d/" port in
          let entered, signal = Eio.Promise.create () in
          let cleaned = ref false
          and closed = ref false
          and cancelled = ref false in
          Eio.Fiber.both
            (fun () ->
              let raw, _ = Eio.Net.accept ~sw listener in
              let t = Httpkit_transport_eio.of_flow raw in
              Fun.protect ~finally:t.close (fun () ->
                  let b = Bytes.create 1 and head = Buffer.create 100 in
                  while
                    not
                      (String.ends_with ~suffix:"\r\n\r\n"
                         (Buffer.contents head))
                  do
                    assert (t.read b 0 1 = 1);
                    Buffer.add_char head (Bytes.get b 0)
                  done;
                  Eio.Flow.copy_string
                    "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n" raw;
                  assert (t.read b 0 1 = 0);
                  closed := true))
            (fun () ->
              C.with_pool ~net ~clock
                ~authenticator:(F.authenticator ~ip:true true) origin
                (fun pool ->
                  Eio.Fiber.fork ~sw (fun () ->
                      try
                        C.request pool origin (fun _ _ ->
                            Fun.protect
                              (fun () ->
                                Eio.Promise.resolve signal ();
                                Eio.Fiber.await_cancel ())
                              ~finally:(fun () ->
                                Eio.Cancel.protect (fun () ->
                                    Eio.Time.Mono.sleep clock 0.01;
                                    cleaned := true)))
                      with Eio.Cancel.Cancelled _ -> cancelled := true);
                  Eio.Promise.await entered);
              assert !cleaned);
          assert (!closed && !cancelled)))

let rec listener_collision attempts tls =
  try run ~collision:true tls false
  with
  | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.EADDRINUSE, _, _)), _)
  when attempts > 1
  ->
    (* An existing IPv6 service may already own the chosen IPv4 port.
         The failed scope closes both fixtures before choosing another port. *)
    listener_collision (attempts - 1) tls

let () =
  Mirage_crypto_rng_unix.use_default ();
  if Measure.enabled () then
    Measure.run ~body_bytes:300 ~requests:100 ~case:"pool-batch" "eio"
      (fun tls _ -> run ~count:100 tls false)
  else
    Alcotest.run "Eio pool"
      [
        ( "ownership",
          [
            Alcotest.test_case "reuse, abandonment, cap, origin and scope"
              `Quick (fun () ->
                match
                  Harness_runtime.Watchdog.run ~seconds:10. (fun () ->
                      List.iter
                        (fun tls -> List.iter (run tls) [ false; true ])
                        [ false; true ];
                      scope_cancellation ();
                      List.iter (listener_collision 10) [ false; true ];
                      List.iter
                        (fun tls ->
                          run ~expire:true tls false;
                          run ~server_close:true tls false;
                          run ~uploading:true tls false)
                        [ false; true ])
                with
                | Exited 0 -> ()
                | _ -> Alcotest.fail "pool failed or hung");
          ] );
      ]
