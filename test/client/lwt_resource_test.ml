open Lwt.Syntax
module C = Httpkit_client_lwt
module F = Client_fixtures

let run tls _ =
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
         let url =
           Printf.sprintf "%s://localhost:%d/"
             (if tls then "https" else "http")
             port
         in
         let accepted = ref 0 and closed = ref 0 and responses = ref 0 in
         let payload = String.make 262144 'x' in
         let serve raw =
           Lwt.finalize
             (fun () ->
               let* t =
                 if not tls then Lwt.return (Httpkit_transport_lwt.of_fd raw)
                 else
                   let* flow = Tls_lwt.Unix.server_of_fd (F.server ()) raw in
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
                   if String.ends_with ~suffix:"\r\n\r\n" (Buffer.contents head)
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
                 else (
                   incr responses;
                   let write bytes =
                     let rec loop off =
                       if off = String.length bytes then Lwt.return_unit
                       else
                         let* n =
                           t.write bytes off (String.length bytes - off)
                         in
                         loop (off + n)
                     in
                     loop 0
                   in
                   let* () =
                     write "HTTP/1.1 200 OK\r\nContent-Length: 262144\r\n\r\n"
                   in
                   let* () = write payload in
                   requests ())
               in
               requests ())
             (fun () -> Lwt_unix.close raw)
         in
         let server =
           let rec accept n workers =
             if n = 0 then Lwt.join workers
             else
               let* raw, _ = Lwt_unix.accept listener in
               incr accepted;
               accept (n - 1) (serve raw :: workers)
           in
           accept 4 []
         in
         let client =
           C.with_pool ~authenticator:(F.authenticator true) ~max_connections:4
             url (fun pool ->
               Lwt_list.iter_p
                 (fun _ ->
                   Lwt_list.iter_s
                     (fun _ ->
                       C.request pool url (fun _ body ->
                           let count = ref 0 in
                           let rec read () =
                             let* chunk = C.read body in
                             match chunk with
                             | None -> Lwt.return_unit
                             | Some bytes ->
                                 assert (String.length bytes <= 16384);
                                 count := !count + String.length bytes;
                                 let* () = Lwt_unix.sleep 0.0001 in
                                 read ()
                           in
                           let* () = read () in
                           assert (!count = 262144);
                           Lwt.return_unit))
                     [ 1; 2; 3; 4 ])
                 [ 1; 2; 3; 4 ])
         in
         let* () = Lwt.join [ server; client ] in
         assert (!accepted = 4 && !closed = 4 && !responses = 16);
         Lwt.return_unit)
       (fun () -> Lwt_unix.close listener))

let () =
  Mirage_crypto_rng_unix.use_default ();
  if Measure.enabled () then
    Measure.run ~case:"concurrent-slow-consumer" ~requests:16
      ~body_bytes:4194304 "lwt" run
  else
    Alcotest.run "Lwt client resources"
      [
        ( "concurrency",
          [
            Alcotest.test_case "bounded four connections and slow consumers"
              `Quick (fun () ->
                match
                  Harness_runtime.Watchdog.run ~seconds:10. (fun () ->
                      List.iter (fun tls -> run tls ()) [ false; true ])
                with
                | Exited 0 -> ()
                | _ -> Alcotest.fail "resource test failed");
          ] );
      ]
