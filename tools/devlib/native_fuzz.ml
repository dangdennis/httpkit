open Common

let check_log log =
  let rows = lines log |> List.map String.trim |> List.filter (( <> ) "") in
  require
    (match rows with [ row ] -> ends ~suffix:": PASS" row | _ -> false)
    "Native fuzz target did not report exactly one passing property"

let main args =
  let rounds = int_of_string (option args "--rounds" "10000")
  and batches = int_of_string (option args "--batches" "3")
  and seed = Int64.of_string (option args "--seed" "42")
  and timeout = float_of_string (option args "--timeout" "120")
  and selected = option args "--target" "all" in
  require
    (rounds > 0 && rounds <= 10000000 && batches > 0 && batches <= 1000
   && seed >= 0L
    && seed <= Int64.sub Int64.max_int (Int64.of_int (batches - 1))
    && Float.is_finite timeout && timeout > 0. && timeout <= 86400.)
    "Invalid native fuzz rounds, batches, seed or per-batch timeout";
  let catalog = json (root / "toolchain/fuzz-targets.json") |> list in
  let targets =
    List.filter
      (fun t -> selected = "all" || field "name" t = `String selected)
      catalog
  in
  require (targets <> []) "Unknown native fuzz target";
  let binaries =
    targets
    |> List.map (fun t -> "fuzz/" ^ string (field "binary" t) ^ ".exe")
    |> List.sort_uniq String.compare
  in
  Build.call ([ "build" ] @ binaries);
  let digest = Build.source_hash () in
  let directory = temp_dir ~parent:(root / "_artifacts/native-fuzz") "run-" in
  let rows = ref [] in
  let report status extra =
    save
      (directory / "report.json")
      (`Assoc
         ([
            ("schema", `Int 1);
            ("status", `String status);
            ("source_sha256", `String digest);
            ("compiler", `String Build.version);
            ("build_profile", `String "dev");
            ( "catalog_sha256",
              `String (sha (read (root / "toolchain/fuzz-targets.json"))) );
            ( "targets",
              strings (List.map (fun t -> string (field "name" t)) targets) );
            ("rounds_per_batch", `Int rounds);
            ("batches_per_target", `Int batches);
            ("first_seed", `String (Int64.to_string seed));
            ("timeout_seconds_per_batch", `Float timeout);
            ("afl", `String "SKIPPED_BY_REQUEST");
            ("release_readiness", `String "NOT_EVALUATED");
            ( "note",
              `String
                "Seeded Crowbar generator trials; length guards may skip \
                 checks. No coverage-guided search, automatic shrinking or \
                 total-memory proof is claimed. Reproduce with the recorded \
                 command and selected case on matching sources." );
            ("runs", `List (List.map ( ! ) !rows));
          ]
         @ extra))
  in
  report "RUNNING" [];
  try
    List.iter
      (fun target ->
        let name = string (field "name" target) in
        let binary =
          Build.binary ("fuzz/" ^ string (field "binary" target) ^ ".exe")
        in
        let env =
          Build.environment ()
          |> List.filter (fun (key, _) ->
              key <> "HTTP_KIT_FUZZ_CASE"
              && (not (starts ~prefix:"AFL_" key))
              && not (starts ~prefix:"__AFL" key))
        in
        let env =
          match field "case" target with
          | `Null -> env
          | case -> set env "HTTP_KIT_FUZZ_CASE" (string case)
        in
        for batch = 0 to batches - 1 do
          require
            (Build.source_hash () = digest)
            "Sources changed before native fuzz batch";
          let seed = Int64.add seed (Int64.of_int batch) |> Int64.to_string in
          let command = [ binary; "-r"; string_of_int rounds; "-s"; seed ] in
          let log = directory / Printf.sprintf "%s-%d.log" name batch in
          let row =
            ref
              (`Assoc
                 [
                   ("target", `String name);
                   ("case", field "case" target);
                   ("seed", `String seed);
                   ("rounds", `Int rounds);
                   ("command", strings command);
                   ("binary_sha256", `String (sha (read binary)));
                   ("log", `String log);
                   ("status", `String "RUNNING");
                 ])
          in
          rows := !rows @ [ row ];
          report "RUNNING" [];
          let start = monotonic () in
          (try
             Process.with_child ~env ~log command (fun child ->
                 let status = Process.wait child (start +. timeout) in
                 row :=
                   Benchmarks.setj "exit"
                     (`Int (Process.status_code status))
                     !row;
                 require
                   (Process.status_code status = 0)
                   ("Native fuzz failed: " ^ log));
             check_log (read log);
             require
               (Build.source_hash () = digest)
               "Sources changed during native fuzz batch";
             row := Benchmarks.setj "status" (`String "PASS") !row
           with exn ->
             row := Benchmarks.setj "status" (`String "FAIL") !row;
             row :=
               Benchmarks.setj "error" (`String (Printexc.to_string exn)) !row;
             row :=
               Benchmarks.setj "seconds" (`Float (monotonic () -. start)) !row;
             raise exn);
          row := Benchmarks.setj "seconds" (`Float (monotonic () -. start)) !row;
          report "RUNNING" [];
          Printf.printf "Native fuzz %s batch %d/%d seed %s: PASS\n%!" name
            (batch + 1) batches seed
        done)
      targets;
    report "PASS" [];
    Printf.printf "PASS native fuzz campaign: %s\n%!" (directory / "report.json")
  with exn ->
    report "FAIL" [ ("error", `String (Printexc.to_string exn)) ];
    raise exn
