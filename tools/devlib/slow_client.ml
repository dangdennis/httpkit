open Common

let scenarios =
  [ "header"; "drip-header"; "body"; "disconnect-body"; "shutdown-body" ]

let select value =
  let values = String.split_on_char ',' value in
  require
    (values <> []
    && List.for_all (fun x -> List.mem x scenarios) values
    && List.length values = List.length (List.sort_uniq compare values))
    "Scenarios must be distinct selections from \
     header,drip-header,body,disconnect-body,shutdown-body";
  values

let body =
  "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65536\r\n\r\nx"

let await_closed ~minimum ~deadline sockets sent sample =
  let bytes = Array.make (Array.length sockets) 0
  and elapsed = Array.make (Array.length sockets) 0.
  and next_sample = ref 0. in
  let buffer = Bytes.create 4096 in
  while Capacity.live sockets <> [] do
    let now = monotonic () in
    require (now < deadline) "Stalled connection outlived its deadline";
    if now >= !next_sample then (
      sample ();
      next_sample := monotonic () +. 1.);
    let ready =
      Capacity.ready (Capacity.live sockets)
        (min 0.25 (max 0. (deadline -. monotonic ())))
    in
    Array.iteri
      (fun i ->
        Option.iter (fun c ->
            if List.exists (( == ) c) ready then
              let count =
                try
                  Unix.recv c.Network.fd buffer 0 (Bytes.length buffer) []
                with
                | Unix.Unix_error (Unix.ECONNRESET, _, _) -> 0
                | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> -1
              in
              if count >= 0 then (
                let observed = monotonic () in
                require (observed <= deadline)
                  "Stalled connection closure observed after its deadline";
                let age = observed -. sent.(i) in
                require (age >= minimum)
                  "Stalled input was rejected before its timeout window";
                bytes.(i) <- bytes.(i) + count;
                require
                  (bytes.(i) <= 65536)
                  "Unbounded response to incomplete input";
                if count = 0 then (
                  elapsed.(i) <- age;
                  Network.close c))))
      sockets
  done;
  `Assoc
    [
      ( "closure_seconds",
        `List (Array.to_list elapsed |> List.map (fun n -> `Float n)) );
      ( "response_bytes",
        `List (Array.to_list bytes |> List.map (fun n -> `Int n)) );
    ]

let run ~capacity ~scenario app baseline =
  let is_header = scenario = "header" || scenario = "drip-header" in
  let sockets = Array.make capacity None in
  let observations = ref [] in
  let sample () =
    let row = Load.process_resources app.Framework.child.pid (`Assoc []) in
    observations := row :: !observations;
    save
      (Filename.dirname app.log / (scenario ^ "-progress.json"))
      (`List (List.rev !observations));
    require
      (int (field "rss_kib" row) <= Capacity.rss_limit
      && int (field "descriptors" row)
         <= int (field "descriptors" baseline) + capacity + 2)
      "Stalled connections exceeded process-resource limits"
  in
  Fun.protect
    ~finally:(fun () -> Capacity.close_all sockets)
    (fun () ->
      Array.iteri
        (fun i _ ->
          let c = Network.connect app.Framework.port in
          sockets.(i) <- Some c;
          let r = Network.request c "GET" "/health" in
          require (r.status = 200 && r.body = "ok\n") "Stall prefill failed")
        sockets;
      let held =
        Capacity.held_snapshot ~capacity app (Option.get sockets.(0))
      in
      let sent = Array.make capacity 0. in
      Array.iteri
        (fun i ->
          Option.iter (fun c ->
              Network.send c (if is_header then "G" else body);
              sent.(i) <- monotonic ()))
        sockets;
      let started = monotonic () in
      sample ();
      let outcome =
        if is_header || scenario = "body" then (
          let duration = if is_header then 10. else 30. in
          let drips = ref 0 in
          let sample () =
            sample ();
            if scenario = "drip-header" && monotonic () -. started < 8. then (
              List.iter (fun c -> Network.send c "x") (Capacity.live sockets);
              incr drips)
          in
          let result =
            await_closed ~minimum:(duration -. 2.)
              ~deadline:(started +. duration +. 5.)
              sockets sent sample
          in
          require
            (scenario <> "drip-header" || !drips >= 5)
            "Insufficient header progress to test the absolute deadline";
          Benchmarks.setj "header_drips_per_live_connection" (`Int !drips)
            result)
        else (
          (* Keep the confirmed admitted connections open after partial input.
             The real-socket runner does not claim handler-entry instrumentation. *)
          sleep 1.;
          sample ();
          if scenario = "disconnect-body" then (
            Array.iter
              (Option.iter (fun c ->
                   Unix.setsockopt_optint c.Network.fd Unix.SO_LINGER (Some 0)))
              sockets;
            Capacity.close_all sockets;
            `Assoc [ ("client_reset", `Bool true) ])
          else (
            Framework.close app;
            await_closed ~minimum:0.
              ~deadline:(monotonic () +. 2.)
              sockets sent
              (fun () -> ())))
      in
      `Assoc
        [
          ("scenario", `String scenario);
          ("capacity", `Int capacity);
          ("seconds", `Float (monotonic () -. started));
          ("held", held);
          ("process_observations", `List (List.rev !observations));
          ("outcome", outcome);
        ])

let main args =
  let capacities = Capacity.capacities (option args "--capacities" "1,16,64")
  and selected =
    select (option args "--scenarios" (String.concat "," scenarios))
  in
  (* Shutdown consumes its server. Put it last without changing the other cases. *)
  let selected =
    List.filter (( <> ) "shutdown-body") selected
    @ if List.mem "shutdown-body" selected then [ "shutdown-body" ] else []
  in
  ignore
    (Process.run
       ~env:(Build.measurement_environment ())
       (Build.command [ "build"; "examples/framework/server.exe" ]));
  let binary = Build.binary "examples/framework/server.exe" in
  let digest = Build.source_hash () and binary_digest = sha (read binary) in
  let directory =
    temp_dir ~parent:(root / "_artifacts/framework") "slow-client-"
  in
  let rows = ref [] in
  let report status extra =
    save
      (directory / "report.json")
      (`Assoc
         ([
            ("status", `String status);
            ("source_sha256", `String digest);
            ("binary_sha256", `String binary_digest);
            ("compiler", `String Build.version);
            ("runtime", `String "eio");
            ("profile", `String "dev");
            ( "os_arch",
              `String
                (String.trim (Process.output ~timeout:5. [ "uname"; "-srm" ]))
            );
            ("scenarios", strings selected);
            ("capacities", `List (List.map (fun n -> `Int n) capacities));
            ("rss_limit_kib", `Int Capacity.rss_limit);
            ( "client_runtime_overrides_inherited",
              `Bool
                (List.exists
                   (fun (key, _) -> Build.measurement_override key)
                   (environment ())) );
            ("results", `List !rows);
            ("public_release", `String "NOT_READY");
            ( "scope",
              `String
                "Real-socket incomplete input deadlines, reset and SIGTERM; \
                 not blocked-reader or sustained campaign acceptance" );
          ]
         @ extra))
  in
  report "RUNNING" [];
  try
    List.iter
      (fun capacity ->
        let dir = directory / Printf.sprintf "capacity-%d" capacity in
        mkdir dir;
        let env =
          set
            (Build.measurement_environment ())
            "HTTPKIT_MAX_CONNECTIONS" (string_of_int capacity)
        in
        Framework.with_app ~env ~binary ~directory:dir (fun app ->
            ignore (Endpoint_profile.counters ~capacity app);
            let baseline =
              Load.resources ~capacity app.port app.child.pid false
            in
            let idle_rows = ref [ baseline ] in
            List.iter
              (fun scenario ->
                require
                  (Build.source_hash () = digest)
                  "Sources changed during slow-client validation";
                let row = run ~capacity ~scenario app baseline in
                let row =
                  if app.closed then row
                  else
                    let idle =
                      Load.resources ~capacity app.port app.child.pid false
                    in
                    Capacity.check_snapshot ~capacity ~active:1 idle;
                    require
                      (int (field "descriptors" idle)
                      <= int (field "descriptors" baseline) + 2)
                      "Stalled connection descriptor leak";
                    idle_rows := !idle_rows @ [ idle ];
                    Load.check_resources ~rss_limit_kib:Capacity.rss_limit
                      !idle_rows;
                    Benchmarks.setj "drained" idle row
                in
                save (dir / (scenario ^ ".json")) row;
                rows := !rows @ [ row ];
                report "RUNNING" [];
                Printf.printf "Slow-client %d %s: PASS\n%!" capacity scenario)
              selected;
            Framework.close app;
            let final = Option.value ~default:`Null app.final in
            require
              (field "active" final = `Int 0
              && field "opened" final = field "closed" final
              && field "unexpected_errors" final = `Int 0)
              "Stalled connection final cleanup failed";
            save (dir / "final.json") final))
      capacities;
    require
      (Build.source_hash () = digest && sha (read binary) = binary_digest)
      "Sources or binary changed during slow-client validation";
    report "PASS" [];
    Printf.printf "PASS slow-client controls: %s\n%!" (directory / "report.json")
  with exn ->
    report "FAIL" [ ("error", `String (Printexc.to_string exn)) ];
    raise exn
