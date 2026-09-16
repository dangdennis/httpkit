open Lwt.Syntax

let endpoint = Result.get_ok (Httpkit_client.prepare "https://localhost/")

let address =
  {
    Unix.ai_family = Unix.PF_INET;
    ai_socktype = Unix.SOCK_STREAM;
    ai_protocol = 0;
    ai_addr = Unix.ADDR_INET (Unix.inet_addr_loopback, 443);
    ai_canonname = "";
  }

let cancel connect timeout =
  Lwt_main.run
    (let entered, signal = Lwt.wait () in
     let finalized = ref false and descriptor = ref None and attempts = ref 0 in
     let block () =
       Lwt.finalize
         (fun () ->
           Lwt.wakeup signal ();
           fst (Lwt.task ()))
         (fun () ->
           let* () = Lwt_unix.sleep 0.001 in
           finalized := true;
           Lwt.return_unit)
     in
     let resolve _ _ _ =
       if connect then Lwt.return [ address; address ] else block ()
     in
     let dial fd _ =
       incr attempts;
       descriptor := Some fd;
       block ()
     in
     let request =
       Network.within 0.02 (fun () ->
           let* _, close = Network.socket ~resolve ~dial endpoint in
           close ())
     in
     let* () =
       if timeout then Lwt.return_unit
       else
         let* () = entered in
         Lwt.cancel request;
         Lwt.return_unit
     in
     let* () =
       Lwt.catch
         (fun () ->
           let* () = request in
           assert false)
         (function
           | Lwt.Canceled when not timeout -> Lwt.return_unit
           | Lwt_unix.Timeout when timeout -> Lwt.return_unit
           | e -> Lwt.fail e)
     in
     assert !finalized;
     assert (!attempts = if connect then 1 else 0);
     Option.iter
       (fun fd -> assert (Lwt_unix.state fd = Lwt_unix.Closed))
       !descriptor;
     Lwt.return_unit)

let fallback () =
  Lwt_main.run
    (let descriptors = ref [] and attempts = ref 0 in
     let resolve _ _ _ = Lwt.return [ address; address ] in
     let dial fd _ =
       descriptors := fd :: !descriptors;
       incr attempts;
       if !attempts = 1 then
         Lwt.fail (Unix.Unix_error (Unix.ECONNREFUSED, "connect", ""))
       else Lwt.return_unit
     in
     let* fd, close = Network.socket ~resolve ~dial endpoint in
     assert (
       !attempts = 2
       && Lwt_unix.state (List.nth !descriptors 1) = Lwt_unix.Closed);
     let* () = close () in
     let* () = close () in
     assert (Lwt_unix.state fd = Lwt_unix.Closed);
     Lwt.return_unit)

let () =
  Alcotest.run "Lwt network cancellation"
    [
      ( "boundaries",
        [
          Alcotest.test_case
            "DNS/connect cancellation and address fallback ownership" `Quick
            (fun () ->
              match
                Harness_runtime.Watchdog.run ~seconds:5. (fun () ->
                    List.iter
                      (fun connect ->
                        List.iter (cancel connect) [ false; true ])
                      [ false; true ];
                    fallback ())
              with
              | Exited 0 -> ()
              | _ -> Alcotest.fail "network cancellation failed");
        ] );
    ]
