module C = Httpkit_client_eio
module H = Httpkit_core
module F = Client_fixtures

let run_impl ?(active = false) tls fixed early =
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
          let produced = ref 0
          and finalized = ref false
          and closed = ref false in
          Eio.Fiber.both
            (fun () ->
              let raw, _ = Eio.Net.accept ~sw socket in
              let t =
                if tls then
                  Httpkit_transport_eio.of_flow
                    (Tls_eio.server_of_flow (F.server ()) raw)
                else Httpkit_transport_eio.of_flow raw
              in
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
                  assert (
                    String.starts_with ~prefix:"POST / HTTP/1.1\r\n"
                      (Buffer.contents head));
                  (if not early then
                     let expected =
                       if fixed then "abc" else "3\r\nabc\r\n0\r\n\r\n"
                     in
                     String.iter
                       (fun c ->
                         Eio.Time.Mono.sleep clock 0.0001;
                         assert (t.read b 0 1 = 1 && Bytes.get b 0 = c))
                       expected);
                  let response =
                    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                  in
                  let rec write off =
                    if off < String.length response then
                      write
                        (off
                        + t.write response off (String.length response - off))
                  in
                  write 0;
                  let rec drain () =
                    if t.read b 0 1 = 0 then closed := true else drain ()
                  in
                  drain ()))
            (fun () ->
              let upload =
                C.upload
                  ?length:(if fixed then Some 3L else None)
                  (fun () ->
                    incr produced;
                    if active then Some (String.make 65536 'x')
                    else if early then
                      Fun.protect
                        (fun () -> Eio.Fiber.await_cancel ())
                        ~finally:(fun () -> finalized := true)
                    else if !produced = 1 then Some "abc"
                    else None)
              in
              C.with_response ~net ~clock ~authenticator:(F.authenticator true)
                ~timeout:2. ~meth:H.Method.post ~upload
                (Printf.sprintf "%s://localhost:%d/"
                   (if tls then "https" else "http")
                   port)
                (fun _ body -> assert (C.read body = None)));
          assert !closed;
          assert (
            if active then !produced > 0
            else if early then !finalized
            else !produced = 2)))

let run ?active tls fixed early =
  try run_impl ?active tls fixed early
  with e ->
    prerr_endline
      (match e with
      | Httpkit_transport_eio.Error failure ->
          Httpkit_transport_eio.failure_to_string failure
      | _ -> Printexc.to_string e);
    raise e

let failure_impl tls mode =
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
                | `Error -> raise Exit
                | `Empty -> Some ""
                | `Oversize -> Some (String.make 65537 'x')
                | `Long -> Some "abcd"
                | `Short -> if !calls = 1 then Some "ab" else None
                | `Cancel ->
                    Fun.protect
                      (fun () -> Eio.Fiber.await_cancel ())
                      ~finally:(fun () ->
                        Eio.Cancel.protect (fun () ->
                            Eio.Time.Mono.sleep clock 0.01;
                            cleaned := true)))
          in
          Eio.Fiber.both
            (fun () ->
              let raw, _ = Eio.Net.accept ~sw listener in
              let t =
                if tls then
                  Httpkit_transport_eio.of_flow
                    (Tls_eio.server_of_flow (F.server ()) raw)
                else Httpkit_transport_eio.of_flow raw
              in
              Fun.protect ~finally:t.close (fun () ->
                  let b = Bytes.create 4096 in
                  let rec drain () =
                    if t.read b 0 4096 = 0 then closed := true else drain ()
                  in
                  drain ()))
            (fun () ->
              (try
                 C.with_response ~net ~clock
                   ~authenticator:(F.authenticator true) ~timeout:0.1
                   ~meth:H.Method.post ~upload url (fun _ _ -> ());
                 assert false
               with
              | Exit -> assert (mode = `Error)
              | Invalid_argument _ -> assert (mode = `Empty || mode = `Oversize)
              | Httpkit_transport_eio.Error
                  (Httpkit_transport_eio.Engine (Httpkit_engine.Protocol _)) ->
                  assert (mode = `Short || mode = `Long)
              | Eio.Time.Timeout -> assert (mode = `Cancel));
              try
                C.with_response ~net ~clock
                  ~authenticator:(F.authenticator true) ~upload url (fun _ _ ->
                    ());
                assert false
              with Invalid_argument _ -> ());
          assert (!closed && !calls > 0);
          if mode = `Cancel then assert !cleaned))

let failure tls mode =
  try failure_impl tls mode
  with e ->
    prerr_endline (Printexc.to_string e);
    raise e

let () =
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run "Eio uploads"
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
