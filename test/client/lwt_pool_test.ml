open Lwt.Syntax
module C = Httpkit_client_lwt
module F = Client_fixtures

let run ?(count = 3) ?(expire = false) ?(uploading = false)
    ?(server_close = false) tls abandon =
  Lwt_main.run
    (let listener = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
     Lwt.finalize
       (fun () ->
         let* () =
           Lwt_unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
         in
         Lwt_unix.listen listener 4;
         let port =
           match Lwt_unix.getsockname listener with
           | Unix.ADDR_INET (_, p) -> p
           | _ -> assert false
         in
         let origin =
           Printf.sprintf "%s://localhost:%d"
             (if tls then "https" else "http")
             port
         in
         let accepted = ref 0 and closed = ref 0 and escaped = ref None in
         let rec serve n =
           if n = 0 then Lwt.return_unit
           else
             let* raw, _ = Lwt_unix.accept listener in
             incr accepted;
             let* () =
               Lwt.finalize
                 (fun () ->
                   let* t =
                     if not tls then
                       Lwt.return (Httpkit_transport_lwt.of_fd raw)
                     else
                       let* flow =
                         Tls_lwt.Unix.server_of_fd (F.server ()) raw
                       in
                       Lwt.return
                         {
                           Httpkit_transport_lwt.read =
                             (fun b off len ->
                               let buf = Bytes.create len in
                               let* n = Tls_lwt.Unix.read flow buf in
                               Bytes.blit buf 0 b off n;
                               Lwt.return n);
                           write =
                             (fun s off len ->
                               let* () =
                                 Tls_lwt.Unix.write flow (String.sub s off len)
                               in
                               Lwt.return len);
                           close = (fun () -> Lwt.return_unit);
                         }
                   in
                   let b = Bytes.create 1 in
                   let rec requests () =
                     let head = Buffer.create 100 in
                     let rec header () =
                       if
                         String.ends_with ~suffix:"\r\n\r\n"
                           (Buffer.contents head)
                       then Lwt.return_true
                       else
                         let* n = t.read b 0 1 in
                         if n = 0 then Lwt.return_false
                         else (
                           Buffer.add_char head (Bytes.get b 0);
                           header ())
                     in
                     let* present = header () in
                     if not present then (
                       incr closed;
                       Lwt.return_unit)
                     else
                       let* () =
                         assert (
                           String.starts_with
                             ~prefix:(if uploading then "POST / " else "GET / ")
                             (Buffer.contents head));
                         if not uploading then Lwt.return_unit
                         else
                           Lwt_list.iter_s
                             (fun c ->
                               let* n = t.read b 0 1 in
                               assert (n = 1 && Bytes.get b 0 = c);
                               Lwt.return_unit)
                             [ 'a'; 'b'; 'c' ]
                       in
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
                         if off = String.length response then Lwt.return_unit
                         else
                           let* n =
                             t.write response off (String.length response - off)
                           in
                           write (off + n)
                       in
                       let* () = write 0 in
                       requests ()
                   in
                   requests ())
                 (fun () -> Lwt_unix.close raw)
             in
             serve (n - 1)
         in
         let server =
           serve (if abandon || expire || server_close then count else 1)
         in
         let client =
           C.with_pool ~authenticator:(F.authenticator true) ~max_connections:1
             ~idle_timeout:(if expire then 0.000001 else 30.)
             origin
             (fun pool ->
               escaped := Some pool;
               let* () =
                 Lwt.catch
                   (fun () ->
                     C.request pool "http://example.invalid/" (fun _ _ ->
                         assert false))
                   (function
                     | Invalid_argument _ -> Lwt.return_unit | e -> Lwt.fail e)
               in
               Lwt_list.iter_s
                 (fun _ ->
                   let upload =
                     if uploading then
                       let sent = ref false in
                       Some
                         (C.upload ~length:3L (fun () ->
                              Lwt.return
                                (if !sent then None
                                 else (
                                   sent := true;
                                   Some "abc"))))
                     else None
                   in
                   C.request pool ?upload
                     ~meth:
                       (if uploading then Httpkit_core.Method.post
                        else Httpkit_core.Method.get)
                     (origin ^ "/")
                     (fun _ body ->
                       let* () =
                         Lwt.catch
                           (fun () ->
                             let* () =
                               C.request pool (origin ^ "/") (fun _ _ ->
                                   Lwt.return_unit)
                             in
                             assert false)
                           (function
                             | C.Pool_exhausted -> Lwt.return_unit
                             | e -> Lwt.fail e)
                       in
                       if abandon then Lwt.return_unit
                       else
                         let rec read () =
                           let* x = C.read body in
                           match x with
                           | None -> Lwt.return_unit
                           | Some _ -> read ()
                         in
                         read ()))
                 (List.init count Fun.id))
         in
         let* () = Lwt.join [ server; client ] in
         assert (
           (!accepted = if abandon || expire || server_close then count else 1)
           && !closed = !accepted);
         Lwt.catch
           (fun () ->
             let* () =
               C.request (Option.get !escaped) (origin ^ "/") (fun _ _ ->
                   Lwt.return_unit)
             in
             assert false)
           (function Invalid_argument _ -> Lwt.return_unit | e -> Lwt.fail e))
       (fun () -> Lwt_unix.close listener))

let scope_cancellation () =
  Lwt_main.run
    (let listener = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
     Lwt.finalize
       (fun () ->
         let* () =
           Lwt_unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
         in
         Lwt_unix.listen listener 1;
         let port =
           match Lwt_unix.getsockname listener with
           | Unix.ADDR_INET (_, p) -> p
           | _ -> assert false
         in
         let origin = Printf.sprintf "http://localhost:%d/" port in
         let entered, signal = Lwt.wait () in
         let cleaned = ref false
         and closed = ref false
         and running = ref None in
         let server =
           let* raw, _ = Lwt_unix.accept listener in
           Lwt.finalize
             (fun () ->
               let t = Httpkit_transport_lwt.of_fd raw in
               let b = Bytes.create 1 and head = Buffer.create 100 in
               let rec header () =
                 if String.ends_with ~suffix:"\r\n\r\n" (Buffer.contents head)
                 then Lwt.return_unit
                 else
                   let* n = t.read b 0 1 in
                   assert (n = 1);
                   Buffer.add_char head (Bytes.get b 0);
                   header ()
               in
               let* () = header () in
               let response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n" in
               let rec write off =
                 if off = String.length response then Lwt.return_unit
                 else
                   let* n =
                     t.write response off (String.length response - off)
                   in
                   write (off + n)
               in
               let* () = write 0 in
               let* n = t.read b 0 1 in
               assert (n = 0);
               closed := true;
               Lwt.return_unit)
             (fun () -> Lwt_unix.close raw)
         in
         let client =
           let* () =
             C.with_pool ~authenticator:(F.authenticator true) origin
               (fun pool ->
                 let request =
                   C.request pool origin (fun _ _ ->
                       Lwt.finalize
                         (fun () ->
                           Lwt.wakeup signal ();
                           fst (Lwt.task ()))
                         (fun () ->
                           let* () = Lwt_unix.sleep 0.01 in
                           cleaned := true;
                           Lwt.return_unit))
                 in
                 running := Some request;
                 entered)
           in
           assert !cleaned;
           Lwt.catch
             (fun () ->
               let* () = Option.get !running in
               assert false)
             (function Lwt.Canceled -> Lwt.return_unit | e -> Lwt.fail e)
         in
         let* () = Lwt.join [ server; client ] in
         assert !closed;
         Lwt.return_unit)
       (fun () -> Lwt_unix.close listener))

let () =
  Mirage_crypto_rng_unix.use_default ();
  if Measure.enabled () then
    Measure.run ~body_bytes:300 ~requests:100 ~case:"pool-batch" "lwt"
      (fun tls _ -> run ~count:100 tls false)
  else
    Alcotest.run "Lwt pool"
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
