open Common

exception Budget

type outcome = Pass | Failure of string

let reduce ~test ~accept original =
  let rec loop data granularity =
    let length = String.length data in
    if length = 0 then data
    else
      let count = min length granularity in
      let rec attempt index =
        if index = count then
          if count = length then data else loop data (min length (2 * count))
        else
          let first = Stdlib.(index * length / count)
          and last = Stdlib.((index + 1) * length / count) in
          let candidate =
            String.sub data 0 first ^ String.sub data last (length - last)
          in
          if test candidate then (
            accept candidate;
            loop candidate (max 2 (count - 1)))
          else attempt (index + 1)
      in
      attempt 0
  in
  loop original 2

let run ~binary ~case ~source_hash ~directory ~attempts ~seconds ~timeout
    original =
  require
    (attempts >= 3 && attempts <= 10000 && Float.is_finite seconds
   && seconds > 0. && seconds <= 86400. && Float.is_finite timeout
   && timeout > 0. && timeout <= 3600.)
    "Invalid minimization budget";
  require (String.length original <= 65536) "Input exceeds 64 KiB";
  let source = source_hash () and binary_hash = sha (read binary) in
  let started = monotonic () in
  let used = ref 0
  and best = ref original
  and runs = ref []
  and signature = ref None in
  let best_path = directory / "best.input" in
  write (directory / "original.input") original;
  write best_path original;
  let env =
    Build.environment ()
    |> List.filter (fun (key, _) ->
        not
          (starts ~prefix:"HTTP_KIT_FUZZ_" key
          || starts ~prefix:"AFL_" key || starts ~prefix:"__AFL" key))
  in
  let env =
    Option.fold ~none:env
      ~some:(fun value -> set env "HTTP_KIT_FUZZ_CASE" value)
      case
  in
  let report status minimal extra =
    save
      (directory / "report.json")
      (`Assoc
         ([
            ("schema", `Int 1);
            ("status", `String status);
            ("source_sha256", `String source);
            ("binary_sha256", `String binary_hash);
            ("binary", `String binary);
            ("case", Option.fold ~none:`Null ~some:(fun x -> `String x) case);
            ("original_sha256", `String (sha original));
            ("original_bytes", `Int (String.length original));
            ("best_sha256", `String (sha !best));
            ("best_bytes", `Int (String.length !best));
            ("best_input", `String best_path);
            ( "failure_sha256",
              Option.fold ~none:`Null
                ~some:(fun x -> `String (sha x))
                !signature );
            ("attempts", `Int !used);
            ("attempt_budget", `Int attempts);
            ("seconds_budget", `Float seconds);
            ("seconds", `Float (monotonic () -. started));
            ("one_byte_deletion_minimal", `Bool minimal);
            ("replays_per_accepted_input", `Int 2);
            ("release_readiness", `String "NOT_EVALUATED");
            ("afl", `String "SKIPPED_BY_REQUEST");
            ("runs", `List (List.rev !runs));
          ]
         @ extra))
  in
  let probe data =
    if !used >= attempts || monotonic () -. started >= seconds then raise Budget;
    require
      (source_hash () = source && sha (read binary) = binary_hash)
      "Source or binary changed during minimization";
    incr used;
    let prefix = directory / Printf.sprintf "probe-%04d" !used in
    let input = prefix ^ ".input"
    and failure = prefix ^ ".failure"
    and log = prefix ^ ".log" in
    write input data;
    let record fields =
      `Assoc (("input", `String input) :: ("log", `String log) :: fields)
    in
    runs := record [ ("outcome", `String "RUNNING") ] :: !runs;
    report "RUNNING" false [];
    let finish fields =
      runs := record fields :: List.tl !runs;
      report "RUNNING" false []
    in
    try
      let child_env =
        set
          (set env "HTTP_KIT_FUZZ_INPUT" input)
          "HTTP_KIT_FUZZ_FAILURE" failure
      in
      let status =
        Process.with_child ~env:child_env ~log [ binary ] (fun child ->
            Process.wait child
              (min (started +. seconds) (monotonic () +. timeout)))
      in
      let result =
        match status with
        | Unix.WEXITED 0 ->
            Native_fuzz.check_log (read log);
            Pass
        | Unix.WEXITED 2 when Sys.file_exists failure ->
            let identity = Native_fuzz.read_input failure in
            require (identity <> "") "Missing property failure identity";
            Failure identity
        | _ ->
            fail "Inconclusive replay exit (%d); inspect %s"
              (Process.status_code status)
              log
      in
      finish
        [
          ( "outcome",
            `String
              (match result with
              | Pass -> "PASS"
              | Failure _ -> "PROPERTY_FAILURE") );
          ( "failure_sha256",
            match result with Pass -> `Null | Failure s -> `String (sha s) );
        ];
      result
    with exn ->
      finish
        [
          ("outcome", `String "INCONCLUSIVE");
          ("error", `String (Printexc.to_string exn));
        ];
      raise exn
  in
  report "RUNNING" false [];
  try
    let first =
      match probe original with
      | Failure s -> s
      | Pass -> fail "Original input passes; nothing to minimize"
    in
    signature := Some first;
    require
      (probe original = Failure first)
      "Original failure is not reproducible";
    let minimal =
      try
        ignore
          (reduce original
             ~test:(fun candidate ->
               match probe candidate with
               | Failure other when other = first ->
                   require
                     (probe candidate = Failure first)
                     "Candidate failure is nondeterministic";
                   true
               | _ -> false)
             ~accept:(fun candidate ->
               best := candidate;
               write best_path candidate;
               report "RUNNING" false []));
        true
      with Budget -> false
    in
    require
      (source_hash () = source && sha (read binary) = binary_hash)
      "Source or binary changed during minimization";
    report (if minimal then "PASS" else "BUDGET_EXHAUSTED") minimal [];
    (!best, minimal, !used)
  with exn ->
    report "FAIL" false [ ("error", `String (Printexc.to_string exn)) ];
    raise exn

let main args =
  let target = option args "--target" "" and input = option args "--input" "" in
  require
    (input <> "" && target <> "" && target <> "all")
    "Minimization requires one --target and --input";
  let catalog = json (root / "toolchain/fuzz-targets.json") |> list in
  let target =
    match
      List.find_opt (fun row -> field "name" row = `String target) catalog
    with
    | Some row -> row
    | None -> fail "Unknown fuzz target"
  in
  let path = "fuzz/" ^ string (field "binary" target) ^ ".exe" in
  let original = Native_fuzz.read_input (absolute input) in
  Build.call [ "build"; path ];
  let directory =
    temp_dir ~parent:(root / "_artifacts/native-minimize") "run-"
  in
  let _, minimal, attempts =
    run ~binary:(Build.binary path)
      ~case:(match field "case" target with `String s -> Some s | _ -> None)
      ~source_hash:Build.source_hash ~directory
      ~attempts:(int_of_string (option args "--attempts" "1000"))
      ~seconds:(float_of_string (option args "--seconds" "300"))
      ~timeout:(float_of_string (option args "--timeout" "5"))
      original
  in
  Printf.printf "%s after %d probes: %s\n%!"
    (if minimal then "MINIMIZED" else "BUDGET_EXHAUSTED")
    attempts
    (directory / "report.json")
