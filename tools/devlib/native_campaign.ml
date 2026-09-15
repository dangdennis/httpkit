open Common

(* A checkpoint contains only completed, independently retained child reports.
   RUNNING/FAIL checkpoints cannot resume: an interrupted attempt must never
   disappear from the history merely because a later attempt passes. *)
let atomic_save path value =
  let temporary =
    Filename.temp_file ~temp_dir:(Filename.dirname path) ".checkpoint-" ""
  in
  Fun.protect
    ~finally:(fun () -> remove temporary)
    (fun () ->
      save temporary value;
      Unix.rename temporary path)

let regular path =
  require
    ((Unix.lstat path).Unix.st_kind = Unix.S_REG)
    "Campaign evidence must be a regular file, without symlinks";
  read path

let parse raw =
  let value = Yojson.Basic.from_string raw in
  require (Release.unique_json value) "Duplicate campaign evidence fields";
  value

let config_valid config =
  let seconds = number (field "seconds" config)
  and checked = int (field "checked" config)
  and seeds = int (field "seeds" config)
  and rounds = int (field "initial_rounds" config)
  and timeout = number (field "timeout" config)
  and seed = Int64.of_string (string (field "first_seed" config)) in
  require
    (Float.is_finite seconds && seconds > 0. && seconds <= 43200. && checked > 0
   && checked <= 1000000000 && seeds > 0 && seeds <= 10000 && rounds > 0
   && rounds <= 10000000 && Float.is_finite timeout && timeout >= 0.1
   && timeout <= 600. && seed >= 0L
    && seed <= Int64.sub Int64.max_int 1000000L)
    "Invalid native campaign duration/count/seed/timeout limits"

let total rows key =
  List.fold_left (fun sum row -> sum +. number (field key row)) 0. rows

let complete config rows =
  List.length rows >= int (field "seeds" config)
  && total rows "checked" >= number (field "checked" config)
  && total rows "seconds" >= number (field "seconds" config)

let next_rounds config rows =
  match List.rev rows with
  | [] -> int (field "initial_rounds" config)
  | row :: _ ->
      let previous = number (field "rounds" row) in
      (* Target at most 30 seconds and half the child timeout. Limit growth to
         fourfold so one unusually fast sample cannot cause an enormous jump. *)
      let desired = min 30. (number (field "timeout" config) /. 2.) in
      let estimate =
        previous *. desired /. max 0.000001 (number (field "seconds" row))
      in
      int_of_float (max 1. (min 10000000. (min (previous *. 4.) estimate)))

let identity targets =
  `Assoc
    [
      ("source_sha256", `String (Build.source_hash ()));
      ("compiler", `String Sys.ocaml_version);
      ("compiler_sha256", `String (sha (regular (Build.compiler ()))));
      ("lock_sha256", `String (sha (regular (root / "dune.lock/lock.dune"))));
      ( "policy_sha256",
        `String (sha (regular (root / "toolchain/release-policy.json"))) );
      ( "catalog_sha256",
        `String (sha (regular (root / "toolchain/fuzz-targets.json"))) );
      ( "binaries",
        `Assoc
          (List.map
             (fun target ->
               let name = string (field "name" target) in
               let binary =
                 Build.binary ("fuzz/" ^ string (field "binary" target) ^ ".exe")
               in
               (name, `String (sha (regular binary))))
             targets) );
    ]

let check_child ~identity ~target ~seed ~rounds report =
  require
    (field "schema" report = `Int 3
    && field "status" report = `String "PASS"
    && field "mode" report = `String "SEEDED"
    && field "compiler" report = field "compiler" identity
    && field "source_sha256" report = field "source_sha256" identity
    && field "catalog_sha256" report = field "catalog_sha256" identity
    && field "targets" report = strings [ target ]
    && field "rounds_per_batch" report = `Int rounds
    && field "batches_per_target" report = `Int 1)
    "Child campaign provenance or status mismatch";
  let row =
    match field "runs" report with
    | `List [ row ] -> row
    | _ -> fail "Campaign child must contain exactly one run"
  in
  require
    (field "status" row = `String "PASS"
    && field "exit" row = `Int 0
    && field "target" row = `String target
    && field "seed" row = `String seed
    && field "rounds" row = `Int rounds
    && field "timing_scope" row = `String "child_campaign"
    && field "binary_sha256" row = field target (field "binaries" identity))
    "Invalid native campaign child run";
  let counts =
    `Assoc
      (("schema", `Int 2)
      :: List.map
           (fun key -> (key, field key row))
           [
             "generated";
             "checked";
             "skipped";
             "failed";
             "maximum_input_bytes";
             "maximum_checked_input_bytes";
             "seconds";
           ])
  in
  Native_fuzz.check_counts ~rounds
    ~wall_seconds:(number (field "wall_seconds" row))
    counts;
  row

let validate ~directory ~identity checkpoint =
  require (Release.unique_json checkpoint) "Duplicate checkpoint fields";
  require
    (field "schema" checkpoint = `Int 1
    && field "identity" checkpoint = identity
    && field "active_batch" checkpoint = `Null
    && List.mem (field "status" checkpoint) [ `String "PAUSED"; `String "PASS" ]
    )
    "Campaign cannot resume: stale identity or failed/interrupted checkpoint";
  let config = field "config" checkpoint in
  config_valid config;
  let targets = List.map fst (assoc (field "binaries" identity)) in
  require
    (field "targets" checkpoint = strings targets)
    "Campaign target inventory changed";
  let entries =
    match field "batches" checkpoint with
    | `List entries -> entries
    | _ -> fail "Invalid campaign batch inventory"
  in
  require (List.length entries <= 1000000) "Campaign batch limit exceeded";
  let expected =
    List.mapi (fun index _ -> Printf.sprintf "batch-%06d" index) entries
  in
  let actual =
    Array.to_list (Sys.readdir directory)
    |> List.filter (starts ~prefix:"batch-")
    |> List.sort String.compare
  in
  require (actual = expected) "Campaign contains an unrecorded or missing batch";
  let seen = Hashtbl.create 16 in
  let rows =
    List.mapi
      (fun index entry ->
        let relative = Printf.sprintf "batch-%06d" index in
        require
          (field "directory" entry = `String relative)
          "Invalid campaign batch path/order";
        let child_directory = directory / relative in
        require
          ((Unix.lstat child_directory).Unix.st_kind = Unix.S_DIR)
          "Campaign child directory is not confined";
        let raw = regular (child_directory / "report.json") in
        require
          (field "sha256" entry = `String (sha raw))
          "Child report changed";
        let target = string (field "target" entry) in
        require (List.mem target targets) "Unexpected campaign target";
        let count = Option.value ~default:0 (Hashtbl.find_opt seen target) in
        let seed =
          Int64.add
            (Int64.of_string (string (field "first_seed" config)))
            (Int64.of_int count)
          |> Int64.to_string
        in
        Hashtbl.replace seen target (count + 1);
        let row =
          check_child ~identity ~target ~seed
            ~rounds:(int (field "rounds" entry))
            (parse raw)
        in
        let stats_path = child_directory / (target ^ "-0.stats.json") in
        let stats = regular stats_path in
        require
          (field "counters_path" row = `String stats_path
          && field "counters_sha256" row = `String (sha stats))
          "Child counters changed";
        let counts = parse stats in
        List.iter
          (fun key ->
            require (field key counts = field key row) "Child counters disagree")
          [
            "generated";
            "checked";
            "skipped";
            "failed";
            "maximum_input_bytes";
            "maximum_checked_input_bytes";
            "seconds";
          ];
        Native_fuzz.check_counts
          ~rounds:(int (field "rounds" row))
          ~wall_seconds:(number (field "wall_seconds" row))
          counts;
        let log = child_directory / (target ^ "-0.log") in
        require (field "log" row = `String log) "Child log path changed";
        let raw_log = regular log in
        require
          (field "log_sha256" entry = `String (sha raw_log))
          "Child log changed";
        Native_fuzz.check_log raw_log;
        row)
      entries
  in
  if field "status" checkpoint = `String "PASS" then
    require
      (List.for_all
         (fun target ->
           complete config
             (List.filter (fun row -> field "target" row = `String target) rows))
         targets)
      "Campaign claims completion without required work";
  rows

let main args =
  let session_seconds =
    float_of_string (option args "--session-seconds" "43200")
  in
  require
    (Float.is_finite session_seconds
    && session_seconds > 0. && session_seconds <= 43200.)
    "Campaign session must be positive and at most 12 hours";
  let deadline = monotonic () +. session_seconds in
  let resume = option args "--resume" "" in
  require
    (resume = ""
    || not
         (List.exists
            (fun flag -> List.mem flag args)
            [
              "--target";
              "--seconds";
              "--checked";
              "--seeds";
              "--rounds";
              "--seed";
              "--timeout";
            ]))
    "Resume may change only the session time budget";
  let directory =
    if resume = "" then
      temp_dir ~parent:(root / "_artifacts/native-campaigns") "run-"
    else Unix.realpath (absolute resume)
  in
  let lock_path = directory / ".lock" in
  if Sys.file_exists lock_path then ignore (regular lock_path);
  let lock = Unix.openfile lock_path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close lock)
    (fun () ->
      (try Unix.lockf lock Unix.F_TLOCK 0
       with Unix.Unix_error _ -> fail "Campaign already has an owner");
      let path = directory / "report.json" in
      let old = if resume = "" then None else Some (parse (regular path)) in
      let catalog = json (root / "toolchain/fuzz-targets.json") |> list in
      let selected = option args "--target" "all" in
      let targets =
        List.filter
          (fun target ->
            let name = field "name" target in
            match old with
            | Some checkpoint ->
                List.mem name (list (field "targets" checkpoint))
            | None -> selected = "all" || name = `String selected)
          catalog
      in
      require (targets <> []) "Unknown native campaign target";
      let policy = json (root / "toolchain/release-policy.json") in
      let config =
        match old with
        | Some checkpoint -> field "config" checkpoint
        | None ->
            `Assoc
              [
                ( "seconds",
                  `Float
                    (float_of_string
                       (option args "--seconds"
                          (string_of_int
                             (int (field "native_seconds_per_target" policy)))))
                );
                ( "checked",
                  `Int
                    (int_of_string
                       (option args "--checked"
                          (string_of_int
                             (int (field "native_checked_per_target" policy)))))
                );
                ( "seeds",
                  `Int
                    (int_of_string
                       (option args "--seeds"
                          (string_of_int
                             (int (field "native_seeds_per_target" policy)))))
                );
                ( "initial_rounds",
                  `Int (int_of_string (option args "--rounds" "10000")) );
                ( "first_seed",
                  `String
                    (Int64.to_string
                       (Int64.of_string (option args "--seed" "42"))) );
                ( "timeout",
                  `Float (float_of_string (option args "--timeout" "120")) );
              ]
      in
      config_valid config;
      Build.call
        ("build"
        :: List.sort_uniq String.compare
             (List.map
                (fun t -> "fuzz/" ^ string (field "binary" t) ^ ".exe")
                targets));
      let current_identity = identity targets in
      let checkpoint =
        ref
          (match old with
          | Some value -> value
          | None ->
              `Assoc
                [
                  ("schema", `Int 1);
                  ("status", `String "PAUSED");
                  ("identity", current_identity);
                  ("config", config);
                  ( "targets",
                    strings
                      (List.map (fun t -> string (field "name" t)) targets) );
                  ("release_readiness", `String "NOT_EVALUATED");
                  ("batches", `List []);
                ])
      in
      let rows =
        ref (validate ~directory ~identity:current_identity !checkpoint)
      in
      let set key value = checkpoint := Benchmarks.setj key value !checkpoint in
      let save () = atomic_save path !checkpoint in
      let for_target name =
        List.filter (fun row -> field "target" row = `String name) !rows
      in
      let pending () =
        List.find_opt
          (fun t ->
            not (complete config (for_target (string (field "name" t)))))
          targets
      in
      save ();
      Printf.printf "Native campaign checkpoint: %s\n%!" path;
      (try
         let rec loop () =
           match pending () with
           | None ->
               set "status" (`String "PASS");
               save ()
           | Some _
             when monotonic () +. number (field "timeout" config) +. 5.
                  >= deadline ->
               set "status" (`String "PAUSED");
               save ()
           | Some target ->
               require
                 (identity targets = current_identity)
                 "Campaign identity changed";
               let name = string (field "name" target) in
               let previous = for_target name in
               let entries = list (field "batches" !checkpoint) in
               require
                 (List.length entries < 1000000)
                 "Campaign batch limit reached";
               let rounds = next_rounds config previous in
               let seed =
                 Int64.add
                   (Int64.of_string (string (field "first_seed" config)))
                   (Int64.of_int (List.length previous))
                 |> Int64.to_string
               in
               let relative =
                 Printf.sprintf "batch-%06d" (List.length entries)
               in
               let child_directory = directory / relative in
               set "status" (`String "RUNNING");
               set "active_batch" (`String relative);
               save ();
               Unix.mkdir child_directory 0o700;
               Native_fuzz.main ~directory:child_directory ~build:false
                 [
                   "--target";
                   name;
                   "--rounds";
                   string_of_int rounds;
                   "--batches";
                   "1";
                   "--seed";
                   seed;
                   "--timeout";
                   string_of_float (number (field "timeout" config));
                 ];
               require
                 (identity targets = current_identity)
                 "Campaign identity changed during batch";
               let raw = regular (child_directory / "report.json") in
               let row =
                 check_child ~identity:current_identity ~target:name ~seed
                   ~rounds (parse raw)
               in
               let entry =
                 `Assoc
                   [
                     ("directory", `String relative);
                     ("target", `String name);
                     ("rounds", `Int rounds);
                     ("sha256", `String (sha raw));
                     ( "log_sha256",
                       `String
                         (sha (regular (child_directory / (name ^ "-0.log"))))
                     );
                   ]
               in
               set "batches" (`List (entries @ [ entry ]));
               set "active_batch" `Null;
               set "status" (`String "PAUSED");
               save ();
               rows := !rows @ [ row ];
               Printf.printf
                 "Campaign %s: %.3fs child time, %.0f checked, %d seeds\n%!"
                 name
                 (total (for_target name) "seconds")
                 (total (for_target name) "checked")
                 (List.length (for_target name));
               loop ()
         in
         loop ()
       with exn ->
         set "status" (`String "FAIL");
         set "error" (`String (Printexc.to_string exn));
         save ();
         raise exn);
      Printf.printf "%s native campaign: %s\n%!"
        (string (field "status" !checkpoint))
        path)
