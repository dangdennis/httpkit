open Devlib
open Common

let rejects f =
  match f () with
  | _ -> failwith "Invalid resumable campaign accepted"
  | exception Error _ -> ()

let () =
  with_temp "httpkit-campaign-test-" (fun directory ->
      let child = directory / "batch-000000" in
      mkdir child;
      let config =
        `Assoc
          [
            ("seconds", `Float 0.1);
            ("checked", `Int 2);
            ("seeds", `Int 1);
            ("initial_rounds", `Int 3);
            ("first_seed", `String "42");
            ("timeout", `Float 1.);
          ]
      in
      let identity =
        `Assoc
          [
            ("source_sha256", `String "source");
            ("compiler", `String Build.version);
            ("catalog_sha256", `String "catalog");
            ("binaries", `Assoc [ ("request", `String "binary") ]);
          ]
      in
      let counts =
        `Assoc
          [
            ("schema", `Int 2);
            ("generated", `Int 3);
            ("checked", `Int 2);
            ("skipped", `Int 1);
            ("failed", `Int 0);
            ("maximum_input_bytes", `Int 100);
            ("maximum_checked_input_bytes", `Int 100);
            ("seconds", `Float 0.1);
          ]
      in
      let stats_path = child / "request-0.stats.json" in
      save stats_path counts;
      let log = child / "request-0.log" in
      write log "request: PASS\n";
      let row =
        `Assoc
          (List.remove_assoc "schema" (assoc counts)
          @ [
              ("status", `String "PASS");
              ("exit", `Int 0);
              ("target", `String "request");
              ("seed", `String "42");
              ("rounds", `Int 3);
              ("timing_scope", `String "child_campaign");
              ("binary_sha256", `String "binary");
              ("wall_seconds", `Float 1.);
              ("counters_path", `String stats_path);
              ("counters_sha256", `String (sha (read stats_path)));
              ("log", `String log);
            ])
      in
      let report =
        `Assoc
          [
            ("schema", `Int 3);
            ("status", `String "PASS");
            ("mode", `String "SEEDED");
            ("compiler", `String Build.version);
            ("source_sha256", `String "source");
            ("catalog_sha256", `String "catalog");
            ("targets", strings [ "request" ]);
            ("rounds_per_batch", `Int 3);
            ("batches_per_target", `Int 1);
            ("runs", `List [ row ]);
          ]
      in
      let report_path = child / "report.json" in
      save report_path report;
      let entry =
        `Assoc
          [
            ("directory", `String "batch-000000");
            ("target", `String "request");
            ("rounds", `Int 3);
            ("sha256", `String (sha (read report_path)));
            ("log_sha256", `String (sha (read log)));
          ]
      in
      let checkpoint =
        `Assoc
          [
            ("schema", `Int 1);
            ("status", `String "PASS");
            ("identity", identity);
            ("config", config);
            ("targets", strings [ "request" ]);
            ("batches", `List [ entry ]);
          ]
      in
      let validate = Native_campaign.validate ~directory ~identity in
      assert (validate checkpoint = [ row ]);
      mkdir (directory / "batch-000001");
      rejects (fun () -> validate checkpoint);
      Unix.rmdir (directory / "batch-000001");
      assert (Native_campaign.next_rounds config [ row ] = 12);
      let fast = Benchmarks.setj "seconds" (`Float 0.000001) row in
      assert (Native_campaign.next_rounds config [ fast ] = 12);
      let slow = Benchmarks.setj "seconds" (`Float 1.) row in
      assert (Native_campaign.next_rounds config [ slow ] = 1);
      List.iter
        (fun (key, value) ->
          rejects (fun () -> validate (Benchmarks.setj key value checkpoint)))
        [
          ("status", `String "FAIL");
          ("status", `String "RUNNING");
          ( "identity",
            Benchmarks.setj "source_sha256" (`String "changed") identity );
          ( "identity",
            Benchmarks.setj "binaries"
              (`Assoc [ ("request", `String "changed") ])
              identity );
          ("batches", `List []);
          ("batches", `List [ entry; entry ]);
          ("targets", strings [ "request"; "response" ]);
          ("config", Benchmarks.setj "seeds" (`Int 2) config);
          ("config", Benchmarks.setj "seconds" (`Float 2.) config);
        ];
      rejects (fun () ->
          validate (`Assoc (("status", `String "PASS") :: assoc checkpoint)));
      write log "request: PASS\nmodified\n";
      rejects (fun () -> validate checkpoint);
      write log "request: PASS\n";
      save stats_path (Benchmarks.setj "checked" (`Int 3) counts);
      rejects (fun () -> validate checkpoint);
      save stats_path counts;
      let malformed =
        Benchmarks.setj "runs"
          (`List [ Benchmarks.setj "seed" (`String "43") row ])
          report
      in
      save report_path malformed;
      let changed_entry =
        Benchmarks.setj "sha256" (`String (sha (read report_path))) entry
      in
      rejects (fun () ->
          validate
            (Benchmarks.setj "batches" (`List [ changed_entry ]) checkpoint));
      save report_path report;
      assert (validate checkpoint = [ row ]);
      let saved = directory / "checkpoint.json" in
      Native_campaign.atomic_save saved checkpoint;
      assert (json saved = checkpoint);
      let paused =
        Benchmarks.setj "status" (`String "PAUSED")
          (Benchmarks.setj "batches" (`List []) checkpoint)
      in
      Native_campaign.atomic_save saved paused;
      rejects (fun () -> validate (json saved));
      Unix.unlink log;
      Unix.symlink stats_path log;
      rejects (fun () -> validate checkpoint));
  print_endline
    "PASS campaign resume rejects stale, interrupted, modified and incomplete \
     evidence"
