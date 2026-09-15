open Common

let run () =
  with_temp "httpkit-release-controls-" (fun directory ->
      let policy =
        `Assoc
          [
            ("schema_version", `Int 2);
            ("native_seconds_per_target", `Int 1800);
            ("native_checked_per_target", `Int 100000);
            ("native_seeds_per_target", `Int 20);
            ( "coverage_minimum_percent",
              `Assoc
                [
                  ("core", `Int 95);
                  ("framework", `Int 85);
                  ("extensions", `Int 80);
                ] );
          ]
      in
      let rows = ref [] in
      let manifest () =
        `Assoc
          [
            ("schema_version", `Int 2);
            ("source_sha256", `String "current");
            ("candidate_commit", `String "candidate");
            ("lock_sha256", `String "locks");
            ("compiler", `String "5.5.0");
            ("reports", `List !rows);
          ]
      in
      let save_manifest () =
        save (directory / "release-manifest.json") (manifest ())
      in
      let put name fields =
        let path = "reports/" ^ name ^ ".json"
        and log = "logs/" ^ name ^ ".log" in
        let data =
          `Assoc
            (("status", `String "PASS")
            :: ("source_sha256", `String "current")
            :: fields)
        in
        save (directory / path) data;
        write (directory / log) ("Synthetic test fixture only: " ^ name);
        let row =
          `Assoc
            [
              ("name", `String name);
              ("path", `String path);
              ("sha256", `String (sha (read (directory / path))));
              ("platform", `String "fixture");
              ("command", strings [ "fixture"; name ]);
              ( "attachments",
                `List
                  [
                    `Assoc
                      [
                        ("path", `String log);
                        ("sha256", `String (sha (read (directory / log))));
                      ];
                  ] );
            ]
        in
        rows :=
          row :: List.filter (fun r -> field "name" r <> `String name) !rows;
        save_manifest ()
      in
      let assess ?(profile = Release.Beta) ?(policy = policy) ?(license = true)
          ?(clean = true) () =
        Release.assess ~profile ~clean ~candidate:"candidate"
          ~lock_sha256:"locks" directory "current" policy Release.fuzz_targets
          license
      in
      let status ?profile () = field "status" (assess ?profile ()) in
      require (status () = `String "NOT_READY") "Missing evidence passed";
      List.iter
        (fun platform ->
          put ("compiler/" ^ platform)
            ([
               ("compiler", `String "5.5.0");
               ("platform", `String platform);
               ("execution", `String "LOCAL");
             ]
            @ List.map
                (fun k -> (k, `Bool true))
                (Release.consumers
                @ [
                    "framework_consumer";
                    "extension_consumer";
                    "framework_integration";
                  ])))
        Release.platforms;
      put "interop"
        [
          ( "results",
            `List
              (List.map
                 (fun lane -> `Assoc [ ("lane", `String lane) ])
                 Release.lanes) );
        ];
      List.iter
        (fun (name, mutants) ->
          put name
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
                     mutants) );
            ])
        [
          ("mutations", Release.mutants);
          ("framework-mutations", Release.framework_mutants);
        ];
      let coverage =
        [
          ("visited", `Int 95);
          ("total", `Int 100);
          ("percent", `Int 95);
          ("missing_files", `List []);
          ("critical_paths_reviewed", `Bool true);
          ("metric", `String "instrumented points, not branches");
        ]
      in
      List.iter
        (fun name -> put ("coverage/" ^ name) coverage)
        [ "core"; "framework"; "extensions" ];
      let runs =
        List.init 20 (fun i ->
            `Assoc
              [
                ("seed", `String (string_of_int i));
                ("status", `String "PASS");
                ("exit", `Int 0);
                ("seconds", `Float 90.);
                ("timing_scope", `String "child_campaign");
                ("failed", `Int 0);
                ("checked", `Int 5000);
                ("skipped", `Int 10);
                ("generated", `Int 5010);
                ("binary_sha256", `String "fixture-binary");
              ])
      in
      let native target =
        [
          ("target", `String target);
          ("mode", `String "NATIVE");
          ("unresolved_findings", `List []);
          ("regression_inventory_replayed", `Bool true);
          ("negative_controls_passed", `Bool true);
          ("runs", `List runs);
        ]
      in
      List.iter
        (fun target -> put ("native/" ^ target) (native target))
        Release.fuzz_targets;
      List.iter
        (fun name ->
          put name
            [
              ("reviewed_by", `String "fixture");
              ("unresolved_findings", `List []);
              ("acceptance_passed", `Bool true);
            ])
        Release.campaigns;
      let scope =
        [
          ( "features",
            `List
              (List.map
                 (fun name ->
                   `Assoc
                     [
                       ("name", `String name); ("status", `String "BETA_TESTED");
                     ])
                 Release.features) );
          ("websocket", `String "EXPERIMENTAL");
          ("public_production_claim", `Bool false);
        ]
      in
      put "support-scope" scope;
      put "private-reporting"
        [
          ("verified_channel", `String "fixture");
          ("verified_by", `String "fixture");
        ];
      require (status () = `String "BETA_READY") "Valid beta rejected";
      require
        (status ~profile:Release.Production () = `String "NOT_READY")
        "Beta became production";
      List.iter
        (fun name ->
          require
            (List.exists
               (fun g ->
                 field "gate" g = `String name
                 && field "required" g = `Bool false
                 && field "status" g = `String "PENDING")
               (list (field "gates" (assess ()))))
            "Missing review hidden from beta")
        Release.reviews;
      let review =
        [
          ("reviewer", `String "synthetic reviewer");
          ("approved", `Bool true);
          ("unresolved_findings", `List []);
          ("independent_of_implementation", `Bool true);
          ("identity_verified_by", `String "synthetic owner");
        ]
      in
      List.iter (fun name -> put name review) Release.reviews;
      require
        (status ~profile:Release.Production () = `String "PRODUCTION_READY")
        "Production fixture rejected";
      let edit fields key value =
        (key, value) :: List.remove_assoc key fields
      in
      let bad ?(profile = Release.Beta) name fields =
        let original = read (directory / ("reports/" ^ name ^ ".json"))
        and old_rows = !rows in
        Fun.protect
          ~finally:(fun () ->
            write (directory / ("reports/" ^ name ^ ".json")) original;
            rows := old_rows;
            save_manifest ())
          (fun () ->
            put name fields;
            require
              (status ~profile () = `String "NOT_READY")
              ("Bad evidence accepted: " ^ name))
      in
      bad "coverage/core" (edit coverage "percent" (`Int 100));
      bad "coverage/core"
        (edit (edit coverage "visited" (`Int 94)) "percent" (`Int 94));
      bad "coverage/extensions"
        (edit coverage "critical_paths_reviewed" (`Bool false));
      bad "support-scope" (edit scope "websocket" (`String "SUPPORTED"));
      bad "support-scope" (edit scope "public_production_claim" (`Bool true));
      bad "native/core" (edit (native "core") "runs" (`List []));
      bad "native/core"
        (edit (native "core") "runs"
           (`List (List.init 20 (fun _ -> List.hd runs))));
      List.iter
        (fun (key, value) ->
          bad "native/core"
            (edit (native "core") "runs"
               (`List
                  (List.map
                     (fun row -> `Assoc (edit (assoc row) key value))
                     runs))))
        [
          ("seconds", `Float 0.1);
          ("timing_scope", `String "batch_with_validation");
          ("failed", `Int 1);
          ("checked", `Int 0);
          ("exit", `Int 7);
          ("status", `String "TIMEOUT");
          ("skipped", `Int (-1));
          ("generated", `Int 4999);
          ("seed", `String "invalid");
        ];
      bad "soak"
        [
          ("reviewed_by", `String "fixture");
          ("unresolved_findings", strings [ "open" ]);
          ("acceptance_passed", `Bool true);
        ];
      bad ~profile:Release.Production "security-review"
        (edit review "independent_of_implementation" (`Bool false));
      require
        (field "status" (assess ~license:false ()) = `String "NOT_READY")
        "Missing license passed";
      require
        (field "status" (assess ~clean:false ()) = `String "NOT_READY")
        "Dirty candidate passed";
      require
        (field "status"
           (assess
              ~policy:
                (`Assoc
                   (edit (assoc policy) "native_seconds_per_target" (`Int 1)))
              ())
        = `String "NOT_READY")
        "Weakened policy passed";
      let original_manifest = read (directory / "release-manifest.json") in
      List.iter
        (fun row ->
          let path = directory / string (field "path" row) in
          let original = read path in
          Fun.protect
            ~finally:(fun () -> write path original)
            (fun () ->
              write path "{broken";
              require
                (status ~profile:Release.Production () = `String "NOT_READY")
                "Tampered report passed");
          let log =
            directory
            / string (field "path" (List.hd (list (field "attachments" row))))
          in
          let original = read log in
          Fun.protect
            ~finally:(fun () -> write log original)
            (fun () ->
              Unix.unlink log;
              require
                (status ~profile:Release.Production () = `String "NOT_READY")
                "Missing attachment passed"))
        !rows;
      List.iter
        (fun (key, value) ->
          save
            (directory / "release-manifest.json")
            (`Assoc (edit (assoc (manifest ())) key value));
          require (status () = `String "NOT_READY") "Stale manifest accepted")
        [
          ("source_sha256", `String "old");
          ("candidate_commit", `String "old");
          ("lock_sha256", `String "old");
          ("reports", `List (List.hd !rows :: !rows));
        ];
      write (directory / "release-manifest.json") original_manifest;
      let path = directory / "fifo" in
      Unix.mkfifo path 0o600;
      let reject path =
        require
          (try
             ignore (Release.read_evidence directory path);
             false
           with Error _ | Unix.Unix_error _ -> true)
          "Unsafe evidence read accepted"
      in
      reject "fifo";
      reject "../outside";
      reject directory;
      Unix.symlink "/etc/hosts" (directory / "escape");
      reject "escape";
      require
        (status () = `String "BETA_READY")
        "Negative controls damaged baseline";
      print_endline
        "PASS beta/production gates, native budgets, provenance and tamper \
         controls")
