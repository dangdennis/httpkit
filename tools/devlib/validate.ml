open Common

let progress message =
  try
    print_endline message;
    flush stdout
  with Sys_error _ | Unix.Unix_error (Unix.EPIPE, _, _) ->
    let fd = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
    Unix.dup2 fd Unix.stdout;
    Unix.close fd

let framework_steps long =
  [
    ("compiler", [ "validate" ]);
    ("runner-cleanup", [ "runner-test" ]);
    ("databases", [ "databases" ]);
    ("framework-coverage", [ "coverage"; "framework" ]);
    ("framework-mutations", [ "mutations"; "framework" ]);
    ("interop", [ "interop" ]);
    ("streaming-bounds", [ "performance" ]);
    ("coverage", [ "coverage" ]);
    ("mutations", [ "mutations" ]);
    ( "sqlite-smoke",
      [ "framework-load"; "--mode"; "smoke"; "--database"; "sqlite" ] );
    ( "postgresql-smoke",
      [ "framework-load"; "--mode"; "smoke"; "--database"; "postgresql" ] );
    ( "profile",
      [ "framework-load"; "--mode"; "profile"; "--database"; "sqlite" ] );
  ]
  @
  if long then
    [
      ( "canary",
        [ "framework-load"; "--mode"; "canary"; "--database"; "sqlite" ] );
      ( "soak",
        [ "framework-load"; "--mode"; "soak"; "--database"; "postgresql" ] );
    ]
  else []

let personal_steps ~long ~skip_afl =
  [ ("compiler", [ "validate" ]) ]
  @ (if skip_afl then [] else [ ("instrumentation", [ "fuzz-smoke" ]) ])
  @ [
      ("interop", [ "interop" ]);
      ("streaming-bounds", [ "performance" ]);
      ("coverage", [ "coverage" ]);
      ("mutations", [ "mutations" ]);
    ]
  @ (if skip_afl then []
     else [ ("historical-timeout-replay", [ "triage-timeout" ]) ])
  @ [
      ("eio-smoke", [ "personal-load"; "--mode"; "smoke" ]);
      ( "eio-profile",
        [ "personal-load"; "--mode"; "profile"; "--seconds"; "10" ] );
    ]
  @
  if long then
    (if skip_afl then [] else [ ("campaigns", [ "fuzz"; "--seconds"; "1800" ]) ])
    @ [
        ("eio-soak", [ "personal-load"; "--mode"; "soak"; "--seconds"; "7200" ]);
      ]
  else []

let sequence ~directory ~digest steps =
  let rows = ref [] in
  List.iter
    (fun (name, args) ->
      require (Build.source_hash () = digest) ("Sources changed before " ^ name);
      let log = directory / (name ^ ".log") in
      let row =
        ref
          (`Assoc
             [
               ("name", `String name);
               ("command", strings (Sys.executable_name :: args));
               ("status", `String "RUNNING");
               ("log", `String log);
             ])
      in
      rows := !rows @ [ row ];
      let save_rows () =
        save (directory / "steps.json") (`List (List.map ( ! ) !rows))
      in
      save_rows ();
      progress (name ^ ": started");
      let start = monotonic () in
      (try
         Process.with_child ~log (Sys.executable_name :: args) (fun child ->
             row := Benchmarks.setj "pid" (`Int child.pid) !row;
             save_rows ();
             let status = Process.wait child (monotonic () +. (7. *. 86400.)) in
             row :=
               `Assoc
                 (List.filter (fun (k, _) -> k <> "status") (assoc !row)
                 @ [
                     ( "status",
                       `String
                         (if Process.status_code status = 0 then "PASS"
                          else "FAIL") );
                     ("exit", `Int (Process.status_code status));
                     ("seconds", `Float (monotonic () -. start));
                   ]);
             save_rows ();
             require
               (Process.status_code status = 0)
               ("Validation failed: " ^ name ^ "; " ^ log))
       with exn ->
         row := Benchmarks.setj "status" (`String "FAIL") !row;
         save_rows ();
         raise exn);
      require (Build.source_hash () = digest) ("Sources changed during " ^ name);
      progress (name ^ ": PASS"))
    steps;
  List.map ( ! ) !rows

let acceptance kind args =
  let long = flag args "--long"
  and skip_afl = kind = "framework" || flag args "--skip-afl" in
  let digest = Build.source_hash ()
  and directory = temp_dir ~parent:(root / "_artifacts" / kind) "validation-" in
  let report =
    ref
      (`Assoc
         [
           ("status", `String "RUNNING");
           ("source_sha256", `String digest);
           ("directory", `String directory);
           ( "afl",
             `String (if skip_afl then "DEFERRED_BY_REQUEST" else "ENABLED") );
           ("steps", `List []);
         ])
  in
  let save_report () = save (directory / "report.json") !report in
  save_report ();
  try
    let steps =
      if kind = "framework" then framework_steps long
      else personal_steps ~long ~skip_afl
    in
    let rows = sequence ~directory ~digest steps in
    report :=
      `Assoc
        [
          ( "status",
            `String
              (if kind = "framework" then "PASS" else "EXPERIMENTS_PASSED") );
          ("source_sha256", `String digest);
          ("directory", `String directory);
          ( "afl",
            `String (if skip_afl then "DEFERRED_BY_REQUEST" else "ENABLED") );
          ("steps", `List rows);
          ("sustained_acceptance", `String (if long then "PASS" else "NOT_RUN"));
          ("public_release", `String "NOT_READY");
          ( "readiness",
            `String (if skip_afl then "NON_AFL_CHECKS_PASSED" else "NOT_READY")
          );
          ( "unresolved_findings",
            strings
              [
                "Historical request timeout remains unexplained.";
                "Core-target timeout investigation remains deferred.";
              ] );
          ( "limitations",
            strings
              [
                "Hosted CI and independent review remain separate gates.";
                "Long workloads run sequentially to preserve process ownership \
                 and evidence.";
              ] );
        ];
    save_report ();
    progress ("PASS: " ^ (directory / "report.json"))
  with exn ->
    let rows = try json (directory / "steps.json") with _ -> `List [] in
    report :=
      Benchmarks.setj "steps" rows
        (Benchmarks.setj "error"
           (`String (Printexc.to_string exn))
           (Benchmarks.setj "status" (`String "FAIL") !report));
    save_report ();
    raise exn

let compiler () =
  let digest = Build.source_hash () in
  mkdir (root / "_artifacts");
  remove (root / "_artifacts/compiler-5.5.0.json");
  Build.call [ "pkg"; "enabled" ];
  Build.call [ "pkg"; "validate-lockdir"; "dune.lock" ];
  Selftest.packages ();
  Build.call [ "build"; "-j"; "4"; "@all"; "@doc" ];
  Build.call [ "runtest"; "--force"; "-j"; "4" ];
  Process.call
    [
      Build.binary "test/runner/main.exe";
      "run";
      "--tier";
      "fast";
      "--count";
      "1000";
      "--report";
      root / "_artifacts/suite-5.5.0.json";
      "--junit";
      root / "_artifacts/suite-5.5.0.xml";
    ];
  Selftest.checks ();
  Process.call [ Sys.executable_name; "coordinator-test" ];
  Selftest.release ();
  Benchmark_test.main ();
  Benchmark_test.selection ();
  Cli_test.main ();
  List.iter Consumers.dispatch
    [ "core"; "protocol"; "adapter"; "middleware"; "router" ];
  Interop.routing ();
  Framework.main [];
  Consumers.framework ();
  Consumers.extensions ();
  List.iter
    (fun (name, count, metric) ->
      let data =
        Yojson.Basic.from_string
          (Build.output [ "exec"; "./bench/" ^ name ^ "_bench.exe" ])
      in
      let rows = list (field "results" data) in
      require (List.length rows = count) ("Benchmark inventory: " ^ name);
      if metric <> "" then
        List.iter
          (fun row ->
            require
              (number (field metric row) > 0.
              && number
                   (field
                      (if name = "router" then "allocated_bytes_per_lookup"
                       else "allocated_bytes_per_op")
                      row)
                 >= 0.)
              "Invalid benchmark measurement")
          rows;
      Build.record (name ^ "-bench-5.5.0.json") (assoc data))
    [
      ("core", 15, "ns_per_op");
      ("http1", 6, "");
      ("router", 12, "ns_per_lookup");
    ];
  require
    (Sys.ocaml_version = Build.version && Build.source_hash () = digest)
    "Compiler mismatch or changed sources";
  Build.record "compiler-5.5.0.json"
    ([
       ("status", `String "PASS");
       ("compiler", `String Build.version);
       ("dependency_manager", `String "dune");
       ("lock_directory", `String "dune.lock");
       ("packages", Build.locked_packages ());
       ("framework_consumer", `Bool true);
       ("framework_integration", `Bool true);
       ("extension_consumer", `Bool true);
       ("odoc", `String "3.2.1");
     ]
    @ List.map (fun k -> (k, `Bool true)) Release.consumers)
