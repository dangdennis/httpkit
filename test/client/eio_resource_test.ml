module C = Httpkit_client_eio
module F = Client_fixtures

let run tls _ =
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
          let url =
            Printf.sprintf "%s://127.0.0.1:%d/"
              (if tls then "https" else "http")
              port
          in
          let accepted = ref 0 and closed = ref 0 and responses = ref 0 in
          let payload = String.make 262144 'x' in
          let serve raw =
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
                      String.ends_with ~suffix:"\r\n\r\n" (Buffer.contents head)
                    then true
                    else if t.read b 0 1 = 0 then false
                    else (
                      Buffer.add_char head (Bytes.get b 0);
                      header ())
                  in
                  if not (header ()) then incr closed
                  else (
                    incr responses;
                    let write bytes =
                      let rec loop off =
                        if off < String.length bytes then
                          loop
                            (off + t.write bytes off (String.length bytes - off))
                      in
                      loop 0
                    in
                    write "HTTP/1.1 200 OK\r\nContent-Length: 262144\r\n\r\n";
                    write payload;
                    requests ())
                in
                requests ())
          in
          Eio.Fiber.both
            (fun () ->
              Eio.Switch.run (fun workers ->
                  for _ = 1 to 4 do
                    let raw, _ = Eio.Net.accept ~sw:workers listener in
                    incr accepted;
                    Eio.Fiber.fork ~sw:workers (fun () -> serve raw)
                  done))
            (fun () ->
              C.with_pool ~net ~clock
                ~authenticator:(F.authenticator ~ip:true true)
                ~max_connections:4 url (fun pool ->
                  Eio.Fiber.all
                    (List.init 4 (fun _ ->
                         fun () ->
                          for _ = 1 to 4 do
                            C.request pool url (fun _ body ->
                                let count = ref 0 in
                                let rec read () =
                                  match C.read body with
                                  | None -> ()
                                  | Some chunk ->
                                      assert (String.length chunk <= 16384);
                                      count := !count + String.length chunk;
                                      Eio.Time.Mono.sleep clock 0.0001;
                                      read ()
                                in
                                read ();
                                assert (!count = 262144))
                          done))));
          assert (!accepted = 4 && !closed = 4 && !responses = 16)))

let () =
  Mirage_crypto_rng_unix.use_default ();
  if Measure.enabled () then
    Measure.run ~case:"concurrent-slow-consumer" ~requests:16
      ~body_bytes:4194304 "eio" run
  else
    Alcotest.run "Eio client resources"
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
