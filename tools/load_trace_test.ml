open Devlib
open Common

let () =
  with_temp "httpkit-load-trace-" (fun directory ->
      let path = directory / "workers.json" in
      Load_trace.with_workers None 2 (fun workers ->
          require (workers = [| None; None |]) "Tracing must be opt-in");
      Load_trace.with_workers (Some path) 1 (fun workers ->
          let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
          Unix.set_nonblock a;
          let c = Network.of_fd ?trace:workers.(0) a in
          Fun.protect
            ~finally:(fun () ->
              Network.close c;
              Unix.close b)
            (fun () ->
              let result = ref None in
              let worker =
                Thread.create
                  (fun () ->
                    result :=
                      Some
                        (try Ok (Network.recv ~timeout:2. c 1)
                         with exn -> Error exn))
                  ()
              in
              Fun.protect
                ~finally:(fun () -> Thread.join worker)
                (fun () ->
                  let deadline = monotonic () +. 1.5 in
                  let rec await () =
                    let row = List.hd (list (field "workers" (json path))) in
                    if field "phase" row <> `String "read-ready" then (
                      require
                        (monotonic () < deadline)
                        "Missing stalled worker snapshot";
                      Unix.sleepf 0.01;
                      await ())
                  in
                  await ();
                  require (Unix.write_substring b "x" 0 1 = 1) "Fixture write");
              require (!result = Some (Ok "x")) "Traced socket read failed";
              Load_trace.completed workers.(0)));
      let row = json path in
      require (field "status" row = `String "complete") "Missing completion";
      let worker = List.hd (list (field "workers" row)) in
      require
        (field "phase" worker = `String "closed"
        && field "completed" worker = `Int 1)
        "Missing cleanup/progress";
      (try Load_trace.with_workers (Some path) 1 (fun _ -> raise Exit)
       with Exit -> ());
      require
        (field "status" (json path) = `String "failed")
        "Failure swallowed");
  print_endline
    "PASS stalled reads remain observable, tracing preserves IO and failure \
     cleanup"
