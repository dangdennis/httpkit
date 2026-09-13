open Common

let main () =
  let digest = Build.source_hash () in
  Build.call
    [
      "build";
      "bench/stream_bench.exe";
      "test/interop/eio_server.exe";
      "test/interop/lwt_server.exe";
    ];
  let samples =
    List.init 5 (fun _ ->
        Yojson.Basic.from_string
          (Process.output ~timeout:30.
             [ Build.binary "bench/stream_bench.exe" ]))
  in
  List.iter
    (fun sample ->
      require
        (field "compiler" sample = `String Build.version
        && field "profile" sample = `String "uninstrumented")
        "Invalid stream benchmark profile";
      let rows = list (field "results" sample) in
      require
        (List.map (field "body_bytes") rows
        = [ `Int 65536; `Int 1048576; `Int 16777216 ])
        "Incomplete stream benchmark";
      List.iter
        (fun row ->
          require
            (int (field "peak_engine_output_bytes" row) > 0
            && int (field "peak_engine_output_bytes" row) <= 32768
            && number (field "allocated_bytes" row) >= 0.
            && number (field "ns" row) > 0.)
            "Stream queue/resource bound")
        rows)
    samples;
  let noise =
    List.init 3 (fun index ->
        let rows =
          List.map
            (fun sample -> List.nth (list (field "results" sample)) index)
            samples
        in
        let values = List.map (fun row -> number (field "ns" row)) rows in
        `Assoc
          [
            ("body_bytes", field "body_bytes" (List.hd rows));
            ("median_ns", `Float (Benchmarks.median values));
            ( "coefficient_of_variation",
              `Float (Benchmarks.stdev values /. Benchmarks.mean values) );
          ])
  in
  let loads =
    List.map
      (fun runtime ->
        Interop.backend runtime (fun port child ->
            let rss = ref []
            and stopped = Atomic.make false
            and error = ref None in
            let sampler =
              Thread.create
                (fun () ->
                  try
                    while not (Atomic.get stopped) do
                      (try
                         let value =
                           int_of_string
                             (String.trim
                                (Process.output ~timeout:2.
                                   [
                                     "ps";
                                     "-o";
                                     "rss=";
                                     "-p";
                                     string_of_int child.Process.pid;
                                   ]))
                         in
                         rss := value :: !rss
                       with Error _ | Failure _ -> ());
                      Load.interruptible_sleep stopped 0.02
                    done
                  with exn -> error := Some exn)
                ()
            in
            let start = monotonic () in
            let outputs =
              Fun.protect
                ~finally:(fun () ->
                  Atomic.set stopped true;
                  Thread.join sampler)
                (fun () ->
                  Load.parallel 4 (fun stop index ->
                      let rng = Random.State.make [| 42 + index |]
                      and latencies = ref []
                      and total = ref 0 in
                      Network.with_connection port (fun c ->
                          for _ = 1 to 50 do
                            require
                              (not (Atomic.get stop))
                              "Peer load worker failed";
                            let sizes = [| 0; 17; 4096; 262144 |] in
                            let size = sizes.(Random.State.int rng 4)
                            and chunked = Random.State.bool rng in
                            let path =
                              if chunked then "/chunked" else "/fixed"
                            in
                            let body = String.make size 'a' in
                            let start = monotonic () in
                            let r =
                              Network.request ~body ~chunked c "POST" path
                            in
                            require
                              (r.status = 200
                              && r.body = Interop.expected "POST" path body)
                              "Mixed workload response";
                            latencies :=
                              ((monotonic () -. start) *. 1e9) :: !latencies;
                            total := !total + size
                          done);
                      (!latencies, !total)))
            in
            Option.iter raise !error;
            let elapsed = monotonic () -. start in
            let values =
              List.concat_map fst outputs |> List.sort Float.compare
            in
            require
              (List.length values = 200 && !rss <> [])
              "Missing load/RSS observations";
            `Assoc
              [
                ("runtime", `String runtime);
                ("requests", `Int 200);
                ("concurrency", `Int 4);
                ( "body_bytes",
                  `Int (List.fold_left (fun n (_, s) -> n + s) 0 outputs) );
                ("elapsed_seconds", `Float elapsed);
                ("p50_ns", `Float (Benchmarks.median values));
                ("p99_ns", `Float (List.nth values 197));
                ("peak_process_rss_kib", `Int (List.fold_left max 0 !rss));
                ("rss_samples", `Int (List.length !rss));
              ]))
      [ "eio"; "lwt" ]
  in
  require
    (Build.source_hash () = digest)
    "Sources changed during performance checks";
  Build.record "performance-5.5.0.json"
    [
      ("status", `String "PASS");
      ("compiler", `String Build.version);
      ("hard_queue_bound", `Int 32768);
      ("sessions", `List samples);
      ("noise", `List noise);
      ("mixed_loads", `List loads);
      ("timing_verdict", `String "ADVISORY");
      ("stable_runner_gate", `String "NOT_READY");
      ( "limitations",
        strings
          [
            "Same-source local samples, not a paired baseline on reserved \
             hardware.";
            "RSS includes runtime, GC and OS effects; queue payload counts are \
             not RSS bounds.";
            "200 mixed requests per adapter are smoke evidence, not the \
             release soak.";
          ] );
    ];
  print_endline "PASS queue bounds and mixed adapter loads; timing ADVISORY"

let profile args =
  let iterations = int_of_string (option args "--iterations" "50")
  and stack = flag args "--stack" in
  let system = String.trim (Process.output [ "uname"; "-s" ]) in
  require
    (iterations >= 1 && iterations <= 10000
    && List.mem system [ "Darwin"; "Linux" ])
    "Invalid profile iterations/system";
  require
    ((not stack) || system = "Darwin")
    "Stack capture uses macOS sample; use perf separately on Linux";
  let env =
    Build.environment ()
    |> List.filter (fun (k, _) ->
        not
          (starts ~prefix:"BISECT_" k || starts ~prefix:"AFL_" k
          || List.mem k
               [
                 "OCAMLPARAM";
                 "OCAMLRUNPARAM";
                 "CAMLRUNPARAM";
                 "DUNE_INSTRUMENT_WITH";
               ]))
  in
  let digest = Build.source_hash () in
  Process.call ~env
    (Build.command
       [
         "build";
         "--profile=release";
         "--build-dir=_build-bench-5.5.0";
         "bench/suite_bench.exe";
       ]);
  let binary = root / "_build-bench-5.5.0/default/bench/suite_bench.exe" in
  let directory = temp_dir ~parent:(root / "_artifacts/body-profiles") "run-" in
  let rows =
    List.concat_map
      (fun implementation ->
        let rows =
          List.map
            (fun mode ->
              let name = implementation ^ "-" ^ mode in
              let result =
                Process.run ~env ~timeout:300.
                  [
                    "/usr/bin/time";
                    (if system = "Darwin" then "-l" else "-v");
                    binary;
                    "--body-profile";
                    implementation ^ "/" ^ mode;
                    "--profile-iterations";
                    string_of_int iterations;
                  ]
              in
              write (directory / (name ^ ".json")) result.stdout;
              write (directory / (name ^ "-resources.txt")) result.stderr;
              Printf.printf "%s passed\n%!" name;
              Yojson.Basic.from_string result.stdout)
            [ "owned-scan"; "borrowed-scan"; "collect" ]
        in
        if stack then
          Process.with_child ~env
            ~log:(directory / (implementation ^ "-sampled.json"))
            [
              binary;
              "--body-profile";
              implementation ^ "/owned-scan";
              "--profile-iterations";
              "1000";
            ]
            (fun child ->
              let r =
                Process.run ~timeout:30. ~check:false
                  [
                    "/usr/bin/sample";
                    string_of_int child.pid;
                    "1";
                    "1";
                    "-file";
                    directory / (implementation ^ "-stacks.txt");
                  ]
              in
              write
                (directory / (implementation ^ "-sample-status.txt"))
                (Printf.sprintf "exit=%d\n%s%s"
                   (Process.status_code r.status)
                   r.stdout r.stderr);
              require (Process.status_code r.status = 0) "Stack capture failed";
              require
                (Process.status_code (Process.wait child (monotonic () +. 300.))
                = 0)
                "Sampled process failed");
        rows)
      [ "httpkit"; "httpaf"; "httpun" ]
  in
  require (Build.source_hash () = digest) "Sources changed during diagnostics";
  save
    (directory / "report.json")
    (`Assoc
       [
         ("source_sha256", `String digest);
         ("compiler", `String Build.version);
         ("system", `String system);
         ("results", `List rows);
         ( "limitations",
           strings
             [
               "Single-fixture diagnostics are not repeated timing comparisons.";
               "GC allocation, live words, Bigarray bytes and OS peak RSS are \
                distinct.";
               "Peak RSS includes runtime, fixture and allocator retention.";
               "Httpkit public Data remains owned in borrowed-scan lanes.";
               "Stack capture uses separate sampled processes.";
             ] );
       ]);
  print_endline (directory / "report.json")
