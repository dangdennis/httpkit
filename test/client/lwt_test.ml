open Lwt.Syntax
module C = Httpkit_client_lwt
module H = Httpkit_core
module F = Client_fixtures

let with_server serve client =
  Lwt_main.run
    (let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
     Lwt.finalize
       (fun () ->
         let* () =
           Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
         in
         Lwt_unix.listen socket 1;
         let port =
           match Lwt_unix.getsockname socket with
           | Unix.ADDR_INET (_, p) -> p
           | _ -> assert false
         in
         let server =
           let* fd, _ = Lwt_unix.accept socket in
           Lwt.finalize (fun () -> serve fd) (fun () -> Lwt_unix.close fd)
         in
         let work = client port in
         Lwt.finalize
           (fun () -> Lwt.join [ server; work ])
           (fun () ->
             Lwt.cancel server;
             Lwt.cancel work;
             Lwt.return_unit))
       (fun () -> Lwt_unix.close socket))

let transport tls fd =
  if not tls then Lwt.return (Httpkit_transport_lwt.of_fd fd)
  else
    let* session = Tls_lwt.Unix.server_of_fd (F.server ()) fd in
    let transport : Httpkit_transport_lwt.transport =
      {
        read =
          (fun dst off len ->
            let buf = Bytes.create len in
            let* n = Tls_lwt.Unix.read session buf in
            Bytes.blit buf 0 dst off n;
            Lwt.return n);
        write =
          (fun src off len ->
            let* () = Tls_lwt.Unix.write session (String.sub src off len) in
            Lwt.return len);
        close = (fun () -> Tls_lwt.Unix.shutdown session `write);
      }
    in
    Lwt.return transport

let scenario tls mode =
  let closed = ref false and escaped = ref None and cleaned = ref false in
  with_server
    (fun fd ->
      let* transport = transport tls fd in
      let head = Buffer.create 128 and b = Bytes.create 1 in
      let rec header () =
        if String.ends_with ~suffix:"\r\n\r\n" (Buffer.contents head) then
          Lwt.return_unit
        else (
          assert (Buffer.length head < 8192);
          let* n = transport.read b 0 1 in
          assert (n = 1);
          Buffer.add_char head (Bytes.get b 0);
          header ())
      in
      let* () = header () in
      assert (
        String.starts_with ~prefix:"GET /a%2Fb?x=%2F HTTP/1.1\r\n"
          (Buffer.contents head));
      let* () =
        if mode = `Head_timeout then Lwt.return_unit
        else
          let bytes =
            if mode = `Body_timeout then
              "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n"
            else if mode = `Redirect then F.redirect
            else if mode = `Large then F.large
            else if
              mode = `Unframed || mode = `Unframed_clean || mode = `Cut_tls
            then F.unframed
            else if mode = `Truncated then F.short
            else F.wire
          in
          let rec write off =
            if off = String.length bytes then Lwt.return_unit
            else
              let* n = transport.write bytes off (String.length bytes - off) in
              write (off + n)
          in
          write 0
      in
      let* () =
        if mode = `Peer_notify || mode = `Unframed_clean then transport.close ()
        else Lwt.return_unit
      in
      let* () =
        if mode = `Cut_tls then
          let bytes = "\x17\x03\x03\x00\x10abc" in
          let rec write off =
            if off = String.length bytes then Lwt.return_unit
            else
              let* n =
                Lwt_unix.write_string fd bytes off (String.length bytes - off)
              in
              write (off + n)
          in
          write 0
        else Lwt.return_unit
      in
      if mode = `Truncated || mode = `Unframed || mode = `Cut_tls then
        Lwt_unix.shutdown fd Unix.SHUTDOWN_SEND;
      let rec eof () =
        Lwt.catch
          (fun () ->
            let* n = transport.read b 0 1 in
            if n = 0 then (
              closed := true;
              Lwt.return_unit)
            else eof ())
          (function
            | Unix.Unix_error (Unix.ECONNRESET, _, _) when mode = `Peer_notify
              ->
                (* A fully framed response can finish before the peer alert is
                   read. Closing with unread TCP bytes may reset the peer. *)
                closed := true;
                Lwt.return_unit
            | End_of_file ->
                closed := true;
                Lwt.return_unit
            | e -> Lwt.fail e)
      in
      eof ())
    (fun port ->
      let url =
        Printf.sprintf "%s://localhost:%d/a%%2Fb?x=%%2F"
          (if tls then "https" else "http")
          port
      in
      Lwt.catch
        (fun () ->
          let* () =
            C.with_response ~authenticator:(F.authenticator true)
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
                | `Abandon -> Lwt.return_unit
                | `Callback_error -> Lwt.fail Exit
                | `Callback_timeout ->
                    Lwt.finalize
                      (fun () -> fst (Lwt.task ()))
                      (fun () ->
                        let* () = Lwt_unix.sleep 0.01 in
                        cleaned := true;
                        Lwt.return_unit)
                | _ ->
                    let data = Buffer.create 3 in
                    let rec read () =
                      let* chunk = C.read body in
                      match chunk with
                      | None -> Lwt.return_unit
                      | Some bytes ->
                          assert (String.length bytes <= 16384);
                          Buffer.add_string data bytes;
                          read ()
                    in
                    let* () = read () in
                    let* eof = C.read body in
                    assert (
                      (Buffer.contents data
                      = if mode = `Large then String.make 200000 'x' else "abc"
                      )
                      && eof = None);
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
                      else [ ("digest", "done") ]);
                    Lwt.return_unit)
          in
          assert (
            mode = `Peer_notify || mode = `Normal || mode = `Abandon
            || mode = `Large || mode = `Redirect || mode = `Unframed_clean);
          Lwt.return_unit)
        (function
          | Httpkit_client.Unframed_https_response -> assert false
          | Httpkit_transport_lwt.Error
              (Httpkit_transport_lwt.Transport Httpkit_client.Tls_truncated) ->
              assert (
                tls && (mode = `Unframed || mode = `Truncated || mode = `Cut_tls));
              Lwt.return_unit
          | Exit ->
              assert (mode = `Callback_error);
              Lwt.return_unit
          | Lwt_unix.Timeout ->
              assert (
                mode = `Head_timeout || mode = `Body_timeout
                || mode = `Callback_timeout);
              Lwt.return_unit
          | Httpkit_transport_lwt.Error
              (Httpkit_transport_lwt.Engine
                 (Httpkit_engine.Protocol Httpkit_http1.Unexpected_eof)) ->
              assert (mode = `Truncated);
              Lwt.return_unit
          | e -> Lwt.fail e));
  assert !closed;
  if mode = `Callback_timeout then assert !cleaned;
  Option.iter
    (fun body ->
      Lwt_main.run
        (Lwt.catch
           (fun () ->
             let* _ = C.read body in
             assert false)
           (function Invalid_argument _ -> Lwt.return_unit | e -> Lwt.fail e)))
    !escaped

let tls_rejection trusted host =
  let produced = ref false in
  with_server
    (fun fd ->
      Lwt.catch
        (fun () ->
          let* _ = Tls_lwt.Unix.server_of_fd (F.server ()) fd in
          Lwt.return_unit)
        (function
          | Tls_lwt.Tls_alert _ | Tls_lwt.Tls_failure _ | End_of_file ->
              Lwt.return_unit
          | e -> Lwt.fail e))
    (fun port ->
      Lwt.catch
        (fun () ->
          let* () =
            C.with_response ~timeout:2. ~authenticator:(F.authenticator trusted)
              ~upload:
                (C.upload (fun () ->
                     produced := true;
                     Lwt.return_none))
              (Printf.sprintf "https://%s:%d/" host port)
              (fun _ _ -> assert false)
          in
          assert false)
        (function
          | Tls_lwt.Tls_failure _ ->
              assert (not !produced);
              Lwt.return_unit
          | e -> Lwt.fail e))

let handshake_timeout () =
  let closed = ref false in
  with_server
    (fun fd ->
      let b = Bytes.create 16384 in
      let rec drain () =
        let* n = Lwt_unix.read fd b 0 (Bytes.length b) in
        if n = 0 then (
          closed := true;
          Lwt.return_unit)
        else drain ()
      in
      drain ())
    (fun port ->
      Lwt.catch
        (fun () ->
          let* () =
            C.with_response ~timeout:0.1 ~authenticator:(F.authenticator true)
              (Printf.sprintf "https://localhost:%d/" port) (fun _ _ ->
                Lwt.return_unit)
          in
          assert false)
        (function Lwt_unix.Timeout -> Lwt.return_unit | e -> Lwt.fail e));
  assert !closed

let () =
  Mirage_crypto_rng_unix.use_default ();
  if Measure.enabled () then Measure.run "lwt" scenario
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
    Alcotest.run "Lwt fetch"
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
            bounded "peer TLS close before client teardown" (fun () ->
                scenario true `Peer_notify);
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
