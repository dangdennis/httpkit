open Lwt.Syntax
module C = Httpkit_client_lwt
module H = Httpkit_core
module F = Client_fixtures

let run_impl ?(active = false) tls fixed early =
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
         let produced = ref 0
         and finalized = ref false
         and closed = ref false in
         let server =
           let* raw, _ = Lwt_unix.accept listener in
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
               let b = Bytes.create 1 and head = Buffer.create 100 in
               let rec headers () =
                 if String.ends_with ~suffix:"\r\n\r\n" (Buffer.contents head)
                 then Lwt.return_unit
                 else
                   let* n = t.read b 0 1 in
                   assert (n = 1);
                   Buffer.add_char head (Bytes.get b 0);
                   headers ()
               in
               let* () = headers () in
               assert (
                 String.starts_with ~prefix:"POST / HTTP/1.1\r\n"
                   (Buffer.contents head));
               let* () =
                 if early then Lwt.return_unit
                 else
                   let expected =
                     if fixed then "abc" else "3\r\nabc\r\n0\r\n\r\n"
                   in
                   Lwt_list.iter_s
                     (fun c ->
                       let* () = Lwt_unix.sleep 0.0001 in
                       let* n = t.read b 0 1 in
                       assert (n = 1 && Bytes.get b 0 = c);
                       Lwt.return_unit)
                     (List.of_seq (String.to_seq expected))
               in
               let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" in
               let rec write off =
                 if off = String.length response then Lwt.return_unit
                 else
                   let* n =
                     t.write response off (String.length response - off)
                   in
                   write (off + n)
               in
               let* () = write 0 in
               let rec drain () =
                 let* n = t.read b 0 1 in
                 if n = 0 then (
                   closed := true;
                   Lwt.return_unit)
                 else drain ()
               in
               drain ())
             (fun () -> Lwt_unix.close raw)
         in
         let upload =
           C.upload
             ?length:(if fixed then Some 3L else None)
             (fun () ->
               incr produced;
               if active then Lwt.return_some (String.make 65536 'x')
               else if early then
                 Lwt.finalize
                   (fun () -> fst (Lwt.task ()))
                   (fun () ->
                     finalized := true;
                     Lwt.return_unit)
               else Lwt.return (if !produced = 1 then Some "abc" else None))
         in
         let client =
           C.with_response ~authenticator:(F.authenticator true) ~timeout:2.
             ~meth:H.Method.post ~upload
             (Printf.sprintf "%s://localhost:%d/"
                (if tls then "https" else "http")
                port)
             (fun _ body ->
               let* chunk = C.read body in
               assert (chunk = None);
               Lwt.return_unit)
         in
         let* () = Lwt.join [ server; client ] in
         assert !closed;
         assert (
           if active then !produced > 0
           else if early then !finalized
           else !produced = 2);
         Lwt.return_unit)
       (fun () -> Lwt_unix.close listener))

let run ?active tls fixed early =
  try run_impl ?active tls fixed early
  with e ->
    prerr_endline
      (match e with
      | Httpkit_transport_lwt.Error failure ->
          Httpkit_transport_lwt.failure_to_string failure
      | _ -> Printexc.to_string e);
    raise e

let failure_impl tls mode =
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
         let url =
           Printf.sprintf "%s://localhost:%d/"
             (if tls then "https" else "http")
             port
         in
         let calls = ref 0 and cleaned = ref false and closed = ref false in
         let upload =
           C.upload ~length:3L (fun () ->
               incr calls;
               match mode with
               | `Error -> Lwt.fail Exit
               | `Empty -> Lwt.return_some ""
               | `Oversize -> Lwt.return_some (String.make 65537 'x')
               | `Long -> Lwt.return_some "abcd"
               | `Short -> Lwt.return (if !calls = 1 then Some "ab" else None)
               | `Cancel ->
                   Lwt.finalize
                     (fun () -> fst (Lwt.task ()))
                     (fun () ->
                       let* () = Lwt_unix.sleep 0.01 in
                       cleaned := true;
                       Lwt.return_unit))
         in
         let server =
           let* raw, _ = Lwt_unix.accept listener in
           Lwt.finalize
             (fun () ->
               let* read =
                 if not tls then
                   Lwt.return (fun b -> Lwt_unix.read raw b 0 (Bytes.length b))
                 else
                   let* flow = Tls_lwt.Unix.server_of_fd (F.server ()) raw in
                   Lwt.return (fun b -> Tls_lwt.Unix.read flow b)
               in
               let b = Bytes.create 4096 in
               let rec drain () =
                 let* n = read b in
                 if n = 0 then (
                   closed := true;
                   Lwt.return_unit)
                 else drain ()
               in
               drain ())
             (fun () -> Lwt_unix.close raw)
         in
         let client =
           let* () =
             Lwt.catch
               (fun () ->
                 let* () =
                   C.with_response ~authenticator:(F.authenticator true)
                     ~timeout:0.1 ~meth:H.Method.post ~upload url (fun _ _ ->
                       Lwt.return_unit)
                 in
                 assert false)
               (function
                 | Exit ->
                     assert (mode = `Error);
                     Lwt.return_unit
                 | Invalid_argument _ ->
                     assert (mode = `Empty || mode = `Oversize);
                     Lwt.return_unit
                 | Httpkit_transport_lwt.Error
                     (Httpkit_transport_lwt.Engine (Httpkit_engine.Protocol _))
                   ->
                     assert (mode = `Short || mode = `Long);
                     Lwt.return_unit
                 | Lwt_unix.Timeout ->
                     assert (mode = `Cancel);
                     Lwt.return_unit
                 | e -> Lwt.fail e)
           in
           Lwt.catch
             (fun () ->
               let* () =
                 C.with_response ~authenticator:(F.authenticator true) ~upload
                   url (fun _ _ -> Lwt.return_unit)
               in
               assert false)
             (function
               | Invalid_argument _ -> Lwt.return_unit | e -> Lwt.fail e)
         in
         let* () = Lwt.join [ server; client ] in
         assert (!closed && !calls > 0);
         if mode = `Cancel then assert !cleaned;
         Lwt.return_unit)
       (fun () -> Lwt_unix.close listener))

let failure tls mode =
  try failure_impl tls mode
  with e ->
    prerr_endline (Printexc.to_string e);
    raise e

let () =
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run "Lwt uploads"
    [
      ( "wire",
        [
          Alcotest.test_case "fixed/chunked slow peer and early response" `Quick
            (fun () ->
              match
                Harness_runtime.Watchdog.run ~seconds:10. (fun () ->
                    List.iter
                      (fun tls ->
                        List.iter
                          (fun fixed ->
                            List.iter (run tls fixed) [ false; true ])
                          [ false; true ])
                      [ false; true ];
                    List.iter
                      (fun tls ->
                        run ~active:true tls false true;
                        List.iter (failure tls)
                          [ `Error; `Empty; `Oversize; `Short; `Long; `Cancel ])
                      [ false; true ])
              with
              | Exited 0 -> ()
              | _ -> Alcotest.fail "upload failed or hung");
        ] );
    ]
