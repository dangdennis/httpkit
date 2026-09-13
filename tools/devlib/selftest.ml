open Common

let rejects f =
  try
    f ();
    false
  with Error _ -> true

let checks () =
  require
    (rejects (fun () -> require false "guard"))
    "Operational guard disabled";
  let rows =
    `List (List.map (fun n -> `Assoc [ ("name", `String n) ]) Release.mutants)
  in
  require
    (Release.inventory rows "name" Release.mutants)
    "Valid inventory rejected";
  List.iter
    (fun rows ->
      require
        (not (Release.inventory rows "name" Release.mutants))
        "Invalid inventory accepted")
    [
      `Null;
      `List [];
      `List [ List.hd (list rows) ];
      `List (List.init 3 (fun _ -> List.hd (list rows)));
      `List [ `Assoc []; `Assoc []; `Assoc [] ];
    ];
  let r =
    Process.run ~check:false
      [ "sh"; "-c"; "printf stdout; printf stderr >&2; exit 7" ]
  in
  require
    (Process.status_code r.status = 7
    && r.stdout = "stdout" && r.stderr = "stderr")
    "Process status/output capture";
  require
    (rejects (fun () -> ignore (Process.run [ "sh"; "-c"; "exit 7" ])))
    "Process failure swallowed";
  with_temp "httpkit-watchdog-" (fun directory ->
      let pidfile = directory / "child" in
      let started = monotonic () in
      require
        (rejects (fun () ->
             ignore
               (Process.run ~timeout:0.1
                  [
                    "sh";
                    "-c";
                    "echo $$ > \"$1\"; exec sleep 30";
                    "watchdog";
                    pidfile;
                  ])))
        "Timeout not enforced";
      require (monotonic () -. started < 3.) "Timeout cleanup stalled";
      let pid = int_of_string (String.trim (read pidfile)) in
      let alive =
        try
          Unix.kill pid 0;
          true
        with Unix.Unix_error (Unix.ESRCH, _, _) -> false
      in
      require (not alive) "Timed-out child leaked");
  let r =
    Network.reference
      "HTTP/1.1 200 OK\r\n\
       Transfer-Encoding: chunked\r\n\
       Set-Cookie: a=1\r\n\
       Set-Cookie: b=2\r\n\
       \r\n\
       3\r\n\
       abc\r\n\
       0\r\n\
       \r\n"
  in
  require
    (r.status = 200 && r.body = "abc"
    && Network.values "set-cookie" r = [ "a=1"; "b=2" ])
    (Printf.sprintf "Independent HTTP reference status=%d body=%S cookies=%s"
       r.status r.body
       (String.concat "," (Network.values "set-cookie" r)));
  print_endline
    "PASS non-removable guards, inventory, process status, timeout cleanup and \
     HTTP reference"

let release () =
  with_temp "httpkit-gates-" (fun directory ->
      let policy =
        `Assoc
          [
            ("fuzz_seconds_per_target", `Int 28800);
            ("coverage_minimum_percent", `Int 95);
            ("required_platforms", strings [ "linux-x86_64/5.5.0" ]);
            ("required_reviews", strings [ "security-review" ]);
            ("required_extended_evidence", strings [ "soak" ]);
          ]
      in
      let check () =
        Release.assess directory "current" policy [ "core" ] true
        |> field "status"
      in
      let put name fields =
        save
          (directory / (name ^ ".json"))
          (`Assoc
             ([
                ("status", `String "PASS"); ("source_sha256", `String "current");
              ]
             @ fields))
      in
      require (check () = `String "NOT_READY") "Missing evidence passed";
      put "compiler-5.5.0"
        ([ ("compiler", `String "5.5.0"); ("odoc", `String "3.2.1") ]
        @ List.map (fun k -> (k, `Bool true)) Release.consumers);
      put "interop-5.5.0"
        [
          ( "results",
            `List
              (List.map
                 (fun lane -> `Assoc [ ("lane", `String lane) ])
                 Release.lanes) );
        ];
      put "afl/evidence"
        [
          ("coverage_maps_differ", `Bool true);
          ("crowbar_assertion_discovered_and_replayed", `Bool true);
        ];
      put "mutations-5.5.0"
        [
          ( "results",
            `List
              (List.map
                 (fun name ->
                   `Assoc
                     [
                       ("name", `String name);
                       ("compiled", `Bool true);
                       ("status", `String "KILLED");
                     ])
                 Release.mutants) );
        ];
      put "coverage"
        [
          ("compiler", `String "5.5.0");
          ("percent", `Int 95);
          ("missing_files", `List []);
        ];
      put "campaign-core"
        [
          ("target", `String "core");
          ("seconds_executed", `Int 28800);
          ("findings", `Int 0);
          ("uninstrumented_replays", `Int 1);
        ];
      put "platform-matrix" [ ("passed", strings [ "linux-x86_64/5.5.0" ]) ];
      put "security-review"
        [
          ("reviewer", `String "fixture");
          ("review_url", `String "fixture");
          ("approved", `Bool true);
          ("unresolved_findings", `List []);
          ("independent_of_implementation", `Bool true);
        ];
      put "soak"
        [
          ("evidence_paths", strings [ "fixture" ]);
          ("approved_by", `String "fixture");
          ("unresolved_findings", `List []);
        ];
      put "private-reporting"
        [
          ("verified_channel", `String "fixture");
          ("verified_by", `String "fixture");
        ];
      require (check () = `String "READY") "Positive release control rejected";
      List.iter
        (fun (name, fields) ->
          let path = directory / (name ^ ".json") in
          let original = read path in
          Fun.protect
            ~finally:(fun () -> write path original)
            (fun () ->
              put name fields;
              require
                (check () = `String "NOT_READY")
                ("Bad evidence accepted: " ^ name)))
        [
          ( "campaign-core",
            [
              ("target", `String "core");
              ("seconds_executed", `Int 30);
              ("findings", `Int 0);
              ("uninstrumented_replays", `Int 1);
            ] );
          ( "coverage",
            [
              ("compiler", `String "5.5.0");
              ("percent", `Float 94.9);
              ("missing_files", `List []);
            ] );
          ( "coverage",
            [
              ("compiler", `String "5.2.1");
              ("percent", `Int 99);
              ("missing_files", `List []);
            ] );
          ( "security-review",
            [
              ("reviewer", `String "fixture");
              ("approved", `Bool true);
              ("unresolved_findings", strings [ "open" ]);
            ] );
          ( "mutations-5.5.0",
            [
              ( "results",
                `List
                  (List.init 3 (fun _ ->
                       `Assoc
                         [
                           ("compiled", `Bool false);
                           ("status", `String "KILLED");
                         ])) );
            ] );
          ("compiler-5.5.0", [ ("compiler", `String "5.2.1") ]);
        ];
      let p = directory / "coverage.json" in
      let data = json p in
      save p
        (`Assoc
           (("source_sha256", `String "old")
           :: List.remove_assoc "source_sha256" (assoc data)));
      require (check () = `String "NOT_READY") "Stale evidence accepted";
      write p "{broken";
      require (check () = `String "NOT_READY") "Malformed evidence accepted";
      print_endline
        "PASS release positive control and missing/stale/shallow/contradictory \
         evidence rejection")

let packages () =
  with_temp "httpkit-lock-" (fun directory ->
      List.iter
        (fun p -> copy (root / p) (directory / p))
        [
          "dune-project";
          "dune-workspace";
          "httpkit-harness.opam";
          "httpkit-core.opam";
          "dune.lock";
          "tools/dune-pkg";
          "toolchain/manifest.json";
        ];
      mkdir (directory / ".toolchain/bin");
      Unix.symlink Build.dune (directory / ".toolchain/bin/dune");
      let run version success args =
        let env =
          set
            (set (environment ()) "HARNESS_COMPILER" version)
            "DUNE_CONFIG__PKG" "disabled"
        in
        let r =
          Process.run ~cwd:directory ~env ~check:false
            ((directory / "tools/dune-pkg") :: args)
        in
        require
          (Process.status_code r.status = 0 = success)
          (r.stdout ^ r.stderr);
        r.stdout ^ r.stderr
      in
      ignore (run "5.5.0" true [ "pkg"; "enabled" ]);
      ignore (run "5.5.0" true [ "pkg"; "validate-lockdir"; "dune.lock" ]);
      let p = directory / "dune-project" in
      write p
        (Str.global_replace
           (Str.regexp_string "(yojson (= 3.0.0))")
           "(yojson (= 0.0.0))" (read p));
      ignore (run "5.5.0" false [ "pkg"; "validate-lockdir" ]);
      remove (directory / "dune.lock");
      require
        (contains (run "5.5.0" false [ "build" ]) "Missing dune.lock")
        "Missing lock silently generated";
      require
        (not (Sys.file_exists (directory / "dune.lock")))
        "Lock regenerated";
      List.iter
        (fun v ->
          require
            (contains (run v false [ "build" ]) "HARNESS_COMPILER must be 5.5.0")
            "Invalid compiler accepted")
        [ "invalid"; "5.2.1" ];
      require
        (List.hd (List.rev (Build.command [ "pkg"; "lock" ])) = "dune.lock")
        "Lock default differs";
      print_endline
        "PASS pinned package management and stale/missing/invalid \
         configuration rejection")

let main args =
  match args with
  | [ "release" ] -> release ()
  | [ "packages" ] -> packages ()
  | [ "checks" ] -> checks ()
  | [] ->
      checks ();
      release ();
      packages ()
  | _ -> fail "Unknown self-test"
