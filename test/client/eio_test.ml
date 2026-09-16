module C = Httpkit_client_eio
module H = Httpkit_core
module F = Client_fixtures

let scenario tls mode =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
          let socket =
            Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr socket with
            | `Tcp (_, p) -> p
            | _ -> assert false
          in
          let closed = ref false
          and escaped = ref None
          and cleaned = ref false in
          Eio.Fiber.both
            (fun () ->
              let flow, _ = Eio.Net.accept ~sw socket in
              Fun.protect
                ~finally:(fun () -> Eio.Flow.close flow)
                (fun () ->
                  let notify = ref (fun () -> ()) in
                  let transport =
                    if tls then (
                      let secure = Tls_eio.server_of_flow (F.server ()) flow in
                      (notify := fun () -> Eio.Flow.shutdown secure `Send);
                      Httpkit_transport_eio.of_flow secure)
                    else Httpkit_transport_eio.of_flow flow
                  in
                  let head = Buffer.create 128 and b = Bytes.create 1 in
                  while
                    not
                      (String.ends_with ~suffix:"\r\n\r\n"
                         (Buffer.contents head))
                  do
                    assert (Buffer.length head < 8192);
                    assert (transport.read b 0 1 = 1);
                    Buffer.add_char head (Bytes.get b 0)
                  done;
                  assert (
                    String.starts_with ~prefix:"GET /a%2Fb?x=%2F HTTP/1.1\r\n"
                      (Buffer.contents head));
                  (if mode <> `Head_timeout then
                     let bytes =
                       if mode = `Body_timeout then
                         "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n"
                       else if mode = `Redirect then F.redirect
                       else if mode = `Large then F.large
                       else if
                         mode = `Unframed || mode = `Unframed_clean
                         || mode = `Cut_tls
                       then F.unframed
                       else if mode = `Truncated then F.short
                       else F.wire
                     in
                     let rec write off =
                       if off < String.length bytes then (
                         let n =
                           transport.write bytes off (String.length bytes - off)
                         in
                         assert (n > 0);
                         write (off + n))
                     in
                     write 0);
                  if mode = `Cut_tls then
                    Eio.Flow.copy_string "\x17\x03\x03\x00\x10abc" flow;
                  if mode = `Unframed_clean then !notify ();
                  if mode = `Truncated || mode = `Unframed || mode = `Cut_tls
                  then Eio.Flow.shutdown flow `Send;
                  let rec eof () =
                    try
                      let n = transport.read b 0 1 in
                      if n = 0 then closed := true else eof ()
                    with End_of_file -> closed := true
                  in
                  eof ()))
            (fun () ->
              let url =
                Printf.sprintf "%s://localhost:%d/a%%2Fb?x=%%2F"
                  (if tls then "https" else "http")
                  port
              in
              try
                C.with_response ~net ~clock
                  ~authenticator:(F.authenticator true)
                  ~timeout:
                    (if
                       mode = `Head_timeout || mode = `Body_timeout
                       || mode = `Callback_timeout
                     then 0.1
                     else 2.)
                  url
                  (fun response body ->
                    assert (
                      H.Status.to_int (H.Response.status response)
                      = if mode = `Redirect then 302 else 200);
                    escaped := Some body;
                    match mode with
                    | `Abandon -> ()
                    | `Callback_error -> raise Exit
                    | `Callback_timeout ->
                        Fun.protect
                          (fun () -> Eio.Fiber.await_cancel ())
                          ~finally:(fun () ->
                            Eio.Cancel.protect (fun () ->
                                Eio.Time.Mono.sleep clock 0.01;
                                cleaned := true))
                    | _ ->
                        let data = Buffer.create 3 in
                        let rec read () =
                          match C.read body with
                          | None -> ()
                          | Some bytes ->
                              assert (String.length bytes <= 16384);
                              Buffer.add_string data bytes;
                              read ()
                        in
                        read ();
                        assert (
                          (Buffer.contents data
                          =
                          if mode = `Large then String.make 200000 'x'
                          else "abc")
                          && C.read body = None);
                        assert (
                          List.map
                            (fun h ->
                              ( H.Header.Name.to_string (H.Header.name h),
                                H.Header.Value.to_string (H.Header.value h) ))
                            (H.Headers.to_list (Option.get (C.trailers body)))
                          =
                          if
                            mode = `Large || mode = `Redirect
                            || mode = `Unframed_clean
                          then []
                          else [ ("digest", "done") ]));
                assert (
                  mode = `Normal || mode = `Abandon || mode = `Large
                  || mode = `Redirect || mode = `Unframed_clean)
              with
              | Httpkit_client.Unframed_https_response -> assert false
              | Httpkit_transport_eio.Error
                  (Httpkit_transport_eio.Transport Httpkit_client.Tls_truncated)
                ->
                  assert (
                    tls
                    && (mode = `Unframed || mode = `Truncated || mode = `Cut_tls))
              | Exit -> assert (mode = `Callback_error)
              | Eio.Time.Timeout ->
                  assert (
                    mode = `Head_timeout || mode = `Body_timeout
                    || mode = `Callback_timeout)
              | Httpkit_transport_eio.Error
                  (Httpkit_transport_eio.Engine
                     (Httpkit_engine.Protocol Httpkit_http1.Unexpected_eof)) ->
                  assert (mode = `Truncated));
          assert !closed;
          if mode = `Callback_timeout then assert !cleaned;
          Option.iter
            (fun body ->
              try
                ignore (C.read body);
                assert false
              with Invalid_argument _ -> ())
            !escaped))

let tls_rejection trusted host =
  let produced = ref false in
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
          let socket =
            Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr socket with
            | `Tcp (_, p) -> p
            | _ -> assert false
          in
          Eio.Fiber.both
            (fun () ->
              let flow, _ = Eio.Net.accept ~sw socket in
              Fun.protect
                ~finally:(fun () -> Eio.Flow.close flow)
                (fun () ->
                  try ignore (Tls_eio.server_of_flow (F.server ()) flow)
                  with
                  | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ | End_of_file ->
                    ()))
            (fun () ->
              try
                C.with_response ~net ~clock ~timeout:2.
                  ~upload:
                    (C.upload (fun () ->
                         produced := true;
                         None))
                  ~authenticator:(F.authenticator trusted)
                  (Printf.sprintf "https://%s:%d/" host port)
                  (fun _ _ -> ());
                assert false
              with Tls_eio.Tls_failure _ -> assert (not !produced))))

let handshake_timeout () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
          let socket =
            Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr socket with
            | `Tcp (_, p) -> p
            | _ -> assert false
          in
          let closed = ref false in
          Eio.Fiber.both
            (fun () ->
              let flow, _ = Eio.Net.accept ~sw socket in
              let t = Httpkit_transport_eio.of_flow flow
              and b = Bytes.create 16384 in
              let rec drain () =
                if t.read b 0 (Bytes.length b) = 0 then closed := true
                else drain ()
              in
              Fun.protect ~finally:t.close drain)
            (fun () ->
              try
                C.with_response ~net ~clock ~timeout:0.1
                  ~authenticator:(F.authenticator true)
                  (Printf.sprintf "https://localhost:%d/" port) (fun _ _ -> ());
                assert false
              with Eio.Time.Timeout -> ());
          assert !closed))

let () =
  Mirage_crypto_rng_unix.use_default ();
  if Measure.enabled () then Measure.run "eio" scenario
  else
    let bounded name f =
      Alcotest.test_case name `Quick (fun () ->
          match
            Harness_runtime.Watchdog.run ~seconds:10. (fun () ->
                try f ()
                with e ->
                  prerr_endline (Printexc.to_string e);
                  raise e)
          with
          | Exited 0 -> ()
          | _ -> Alcotest.fail "client child failed or hung")
    in
    Alcotest.run "Eio fetch"
      [
        ( "lifecycle",
          [
            bounded "HTTP streaming and cleanup" (fun () ->
                List.iter (scenario false)
                  [
                    `Normal;
                    `Large;
                    `Redirect;
                    `Abandon;
                    `Callback_error;
                    `Truncated;
                    `Head_timeout;
                    `Body_timeout;
                    `Callback_timeout;
                  ]);
            bounded "HTTPS streaming and cleanup" (fun () ->
                List.iter (scenario true)
                  [
                    `Normal;
                    `Large;
                    `Redirect;
                    `Abandon;
                    `Callback_error;
                    `Truncated;
                    `Head_timeout;
                    `Body_timeout;
                    `Callback_timeout;
                  ]);
            bounded "authenticated TLS close-delimited" (fun () ->
                scenario true `Unframed_clean);
            bounded "abrupt TLS EOF rejected" (fun () ->
                scenario true `Unframed);
            bounded "cut TLS record rejected" (fun () -> scenario true `Cut_tls);
            bounded "TLS handshake deadline cleanup" handshake_timeout;
            bounded "untrusted certificate" (fun () ->
                tls_rejection false "localhost");
            bounded "wrong hostname" (fun () -> tls_rejection true "127.0.0.1");
          ] );
      ]
