module C = Httpkit_client_eio
module F = Client_fixtures

let cancellation connect timeout =
  Eio_main.run (fun env ->
      let net = Eio_mock.Net.make "cancelled client" in
      let clock = Eio.Stdenv.mono_clock env in
      let entered, signal = Eio.Promise.create () in
      let cleaned = ref false in
      let block () =
        Fun.protect
          (fun () ->
            Eio.Promise.resolve signal ();
            Eio.Fiber.await_cancel ())
          ~finally:(fun () ->
            Eio.Cancel.protect (fun () ->
                Eio.Time.Mono.sleep clock 0.001;
                cleaned := true))
      in
      if connect then (
        Eio_mock.Net.on_getaddrinfo net
          [ `Return [ `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) ] ];
        Eio_mock.Net.on_connect net [ `Run block ])
      else Eio_mock.Net.on_getaddrinfo net [ `Run block ];
      let request () =
        C.with_response ~net ~clock ~timeout:0.02
          ~authenticator:(F.authenticator true) "https://localhost/" (fun _ _ ->
            ())
      in
      if timeout then
        try
          request ();
          assert false
        with Eio.Time.Timeout -> ()
      else Eio.Fiber.first request (fun () -> Eio.Promise.await entered);
      assert !cleaned)

let () =
  Alcotest.run "Eio network cancellation"
    [
      ( "boundaries",
        [
          Alcotest.test_case
            "DNS/connect deadline and parent cancellation join cleanup" `Quick
            (fun () ->
              match
                Harness_runtime.Watchdog.run ~seconds:5. (fun () ->
                    List.iter
                      (fun connect ->
                        List.iter (cancellation connect) [ false; true ])
                      [ false; true ])
              with
              | Exited 0 -> ()
              | _ -> Alcotest.fail "network cancellation failed");
        ] );
    ]
