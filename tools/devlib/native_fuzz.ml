open Common

let check_log log =
  let rows = lines log |> List.map String.trim |> List.filter (( <> ) "") in
  require
    (match rows with [ row ] -> ends ~suffix:": PASS" row | _ -> false)
    "Native fuzz target did not report exactly one passing property"

let check_counts ~rounds ~wall_seconds data =
  require
    (List.sort String.compare (List.map fst (assoc data))
    = List.sort String.compare
        [
          "schema";
          "generated";
          "checked";
          "skipped";
          "failed";
          "maximum_input_bytes";
          "maximum_checked_input_bytes";
          "seconds";
        ])
    "Invalid or duplicated native fuzz counter fields";
  let generated = int (field "generated" data)
  and checked = int (field "checked" data)
  and skipped = int (field "skipped" data)
  and failed = int (field "failed" data)
  and maximum = int (field "maximum_input_bytes" data)
  and checked_maximum = int (field "maximum_checked_input_bytes" data) in
  let seconds = number (field "seconds" data) in
  require
    (field "schema" data = `Int 2
    && generated = rounds && checked > 0 && skipped >= 0 && checked <= generated
    && skipped = generated - checked
    && failed = 0 && maximum >= 0 && maximum <= 65536 && checked_maximum >= 0
    && checked_maximum <= maximum && Float.is_finite seconds && seconds >= 0.
    && Float.is_finite wall_seconds
    && seconds <= wall_seconds)
    "Native fuzz counters do not prove completed checks for requested trials"

let read_input path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let stat = Unix.fstat fd in
      require
        (stat.st_kind = Unix.S_REG)
        "Raw fuzz input must be a regular file";
      require (stat.st_size <= 65536) "Raw fuzz input exceeds 64 KiB";
      let data = Bytes.create (stat.st_size + 1) in
      let rec loop offset =
        require (offset <= stat.st_size) "Raw fuzz input grew while reading";
        match Unix.read fd data offset (Bytes.length data - offset) with
        | 0 -> Bytes.sub_string data 0 offset
        | count -> loop (offset + count)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
      in
      loop 0)

let main args =
  let input = option args "--input" "" in
  let replay = input <> "" in
  require
    ((not replay)
    || option args "--target" "all" <> "all"
       && not
            (List.exists
               (fun flag -> List.mem flag args)
               [ "--rounds"; "--batches"; "--seed" ]))
    "Raw replay requires one target and cannot set generator options";
  let input_data =
    if not replay then None else Some (read_input (absolute input))
  in
  let rounds =
    int_of_string (option args "--rounds" (if replay then "1" else "10000"))
  and batches =
    int_of_string (option args "--batches" (if replay then "1" else "3"))
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
  let replay_path = directory / "replay.input" in
  Option.iter (write replay_path) input_data;
  let rows = ref [] in
  let report status extra =
    save
      (directory / "report.json")
      (`Assoc
         ([
            ("schema", `Int 3);
            ("status", `String status);
            ("source_sha256", `String digest);
            ("compiler", `String Build.version);
            ("build_profile", `String "dev");
            ("mode", `String (if replay then "RAW_REPLAY" else "SEEDED"));
            ( "input_sha256",
              Option.fold ~none:`Null
                ~some:(fun data -> `String (sha data))
                input_data );
            ( "catalog_sha256",
              `String (sha (read (root / "toolchain/fuzz-targets.json"))) );
            ( "targets",
              strings (List.map (fun t -> string (field "name" t)) targets) );
            ("rounds_per_batch", `Int rounds);
            ("batches_per_target", `Int batches);
            ( "first_seed",
              if replay then `Null else `String (Int64.to_string seed) );
            ("timeout_seconds_per_batch", `Float timeout);
            ("afl", `String "SKIPPED_BY_REQUEST");
            ("release_readiness", `String "NOT_EVALUATED");
            ( "note",
              `String
                "Seeded Crowbar trials or raw-input replay; checked and \
                 skipped callbacks are counted separately. No coverage-guided \
                 search, automatic shrinking or total-memory proof is claimed. \
                 Reproduce with the recorded command and selected case on \
                 matching sources." );
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
              (not
                 (List.mem key
                    [
                      "HTTP_KIT_FUZZ_CASE";
                      "HTTP_KIT_FUZZ_INPUT";
                      "HTTP_KIT_FUZZ_CAPTURE";
                      "HTTP_KIT_FUZZ_FAILURE";
                      "HTTP_KIT_FUZZ_STATS";
                    ]))
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
          let command =
            if replay then [ binary ]
            else [ binary; "-r"; string_of_int rounds; "-s"; seed ]
          in
          let log = directory / Printf.sprintf "%s-%d.log" name batch in
          let capture = directory / Printf.sprintf "%s-%d.input" name batch in
          let stats =
            directory / Printf.sprintf "%s-%d.stats.json" name batch
          in
          let env =
            set
              (set env "HTTP_KIT_FUZZ_CAPTURE" capture)
              "HTTP_KIT_FUZZ_STATS" stats
          in
          let env =
            if replay then set env "HTTP_KIT_FUZZ_INPUT" replay_path else env
          in
          let row =
            ref
              (`Assoc
                 [
                   ("target", `String name);
                   ("case", field "case" target);
                   ("seed", if replay then `Null else `String seed);
                   ("rounds", `Int rounds);
                   ("command", strings command);
                   ("binary_sha256", `String (sha (read binary)));
                   ("log", `String log);
                   ("counters_path", `String stats);
                   ("timing_scope", `String "child_campaign");
                   ("seconds", `Null);
                   ( "replay_input",
                     if replay then `String replay_path else `Null );
                   ("failure_input", `Null);
                   ("status", `String "RUNNING");
                 ])
          in
          rows := !rows @ [ row ];
          report "RUNNING" [];
          let start = monotonic () in
          (try
             Process.with_child ~env ~log command (fun child ->
                 let running = monotonic () in
                 let status = Process.wait child (start +. timeout) in
                 row :=
                   Benchmarks.setj "wait_seconds"
                     (`Float (monotonic () -. running))
                     !row;
                 row :=
                   Benchmarks.setj "exit"
                     (`Int (Process.status_code status))
                     !row;
                 require
                   (Process.status_code status = 0)
                   ("Native fuzz failed: " ^ log));
             check_log (read log);
             let raw_counts = read_input stats in
             let counts = Yojson.Basic.from_string raw_counts in
             check_counts ~rounds ~wall_seconds:(monotonic () -. start) counts;
             List.iter
               (fun key -> row := Benchmarks.setj key (field key counts) !row)
               [
                 "generated";
                 "checked";
                 "skipped";
                 "failed";
                 "maximum_input_bytes";
                 "maximum_checked_input_bytes";
                 "seconds";
               ];
             row :=
               Benchmarks.setj "counters_sha256" (`String (sha raw_counts)) !row;
             require
               (Build.source_hash () = digest)
               "Sources changed during native fuzz batch";
             row := Benchmarks.setj "status" (`String "PASS") !row
           with exn ->
             (try
                if Sys.file_exists capture then
                  row :=
                    Benchmarks.setj "failure_input"
                      (`Assoc
                         [
                           ("path", `String capture);
                           ("sha256", `String (sha (read_input capture)));
                         ])
                      !row
              with capture_error ->
                row :=
                  Benchmarks.setj "capture_error"
                    (`String (Printexc.to_string capture_error))
                    !row);
             row := Benchmarks.setj "status" (`String "FAIL") !row;
             row :=
               Benchmarks.setj "error" (`String (Printexc.to_string exn)) !row;
             row :=
               Benchmarks.setj "wall_seconds"
                 (`Float (monotonic () -. start))
                 !row;
             raise exn);
          row :=
            Benchmarks.setj "wall_seconds" (`Float (monotonic () -. start)) !row;
          report "RUNNING" [];
          if replay then
            Printf.printf "Native fuzz %s raw replay: PASS\n%!" name
          else
            Printf.printf "Native fuzz %s batch %d/%d seed %s: PASS\n%!" name
              (batch + 1) batches seed
        done)
      targets;
    report "PASS" [];
    Printf.printf "PASS native fuzz campaign: %s\n%!" (directory / "report.json")
  with exn ->
    report "FAIL" [ ("error", `String (Printexc.to_string exn)) ];
    raise exn
