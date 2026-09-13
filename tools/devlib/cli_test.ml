open Common

let main () =
  Build.call [ "build"; "test/runner/main.exe" ];
  let run ?(code = 0) args =
    let r =
      Process.run ~check:false ~timeout:60.
        (Build.binary "test/runner/main.exe" :: args)
    in
    require
      (Process.status_code r.status = code)
      ("Harness exit mismatch: " ^ r.stdout ^ r.stderr);
    Yojson.Basic.from_string r.stdout
  in
  with_temp "httpkit-cli-" (fun dir ->
      let fixture = dir / "fault.json" in
      ignore (run [ "example"; "drop-write"; fixture ]);
      let failed =
        run ~code:1 [ "replay"; fixture; "--subject"; "drop-write" ]
      in
      require
        (field "result" failed |> field "failure" |> field "rule"
       = `String "OUTPUT.EXACT")
        "Replay rule";
      require
        (field "provenance" failed |> field "compiler" = `String Build.version)
        "Replay compiler";
      let packages =
        Yojson.Basic.from_string
          (string (field "packages" (field "provenance" failed)))
      in
      require
        (field "lock_directory" packages = `String "dune.lock"
        && field "yojson.3.0.0.pkg" (field "packages" packages) <> `Null)
        "Replay package provenance";
      ignore (run [ "replay"; fixture ]);
      let original = read fixture in
      ignore
        (run ~code:2
           [ "shrink"; fixture; "--subject"; "drop-write"; "--output"; fixture ]);
      require (read fixture = original) "Shrink overwrote input";
      ignore
        (run
           [
             "shrink";
             fixture;
             "--subject";
             "drop-write";
             "--output";
             dir / "small.json";
           ]);
      ignore
        (run ~code:1
           [ "replay"; dir / "small.json"; "--subject"; "drop-write" ]);
      ignore (run ~code:3 [ "run"; "--suite"; "missing" ]);
      ignore (run ~code:3 [ "run"; "--tier"; "nightly" ]);
      ignore (run ~code:2 [ "run"; "--count" ]);
      let release = run ~code:3 [ "readiness"; "--release" ] in
      require
        (field "status" release = `String "NOT_READY"
        && List.exists
             (fun g -> field "status" g = `String "NOT_READY")
             (list (field "gates" release)))
        "Release readiness";
      require
        (Benchmarks.equal release
           (run ~code:3 [ "readiness"; "--milestone"; "M7" ]))
        "M7 readiness mismatch";
      require
        (Benchmarks.equal release (Release.current ()))
        "CLI and direct release differ";
      write fixture "{bad";
      ignore (run ~code:2 [ "replay"; fixture ]);
      let report =
        run
          [
            "run";
            "--suite";
            "property";
            "--count";
            "5";
            "--report";
            dir / "report.json";
            "--junit";
            dir / "report.xml";
          ]
      in
      require
        (field "executed" report = `Int 4
        && Benchmarks.equal report (json (dir / "report.json")))
        "JSON report differs";
      require (contains (read (dir / "report.xml")) "tests=\"4\"") "JUnit count";
      let core = run [ "run"; "--suite"; "core"; "--count"; "5" ] in
      require
        (field "executed" core = `Int 18
        && field "scope" core = `String "M2 core values")
        "Core inventory");
  print_endline
    "PASS CLI exit codes, replay, shrinking, JSON/JUnit and release status"
