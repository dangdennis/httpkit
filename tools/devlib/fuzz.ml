open Common

let afl = root / ".toolchain/afl"
let build_dir = "_build-fuzz-pkg-5.5.0"
let binary name = root / build_dir / "default/fuzz" / (name ^ ".exe")
let plain name = Build.binary ("fuzz/" ^ name ^ ".exe")

(* Preserve the existing fuzz environment variables so retained replay commands
   continue to select the same cases and fault controls after library renames. *)
let environment () =
  List.fold_left
    (fun env (k, v) -> set env k v)
    (List.remove_assoc "HTTP_KIT_FUZZ_CASE" (Build.environment ()))
    [
      ("AFL_SKIP_CPUFREQ", "1");
      ("AFL_NO_AFFINITY", "1");
      ("AFL_MAP_SIZE", "65536");
      ("AFL_CRASH_EXITCODE", "2");
      ("AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES", "1");
      ("AFL_NO_UI", "1");
    ]

let verify () =
  List.iter
    (fun name ->
      require (Sys.file_exists (afl / name)) "AFL missing: mise run setup:afl")
    [ "afl-fuzz"; "afl-showmap" ];
  let pin =
    Str.split (Str.regexp "[ \n\t]+") (read (root / "toolchain/afl.version"))
    |> fun xs -> List.nth xs 2
  in
  require
    (String.trim (Process.output [ "git"; "-C"; afl; "rev-parse"; "HEAD" ])
    = pin)
    "AFL revision mismatch";
  Process.call [ "git"; "-C"; afl; "diff"; "--quiet"; "HEAD"; "--" ];
  pin

let build names =
  let names =
    List.sort_uniq String.compare names
    |> List.map (fun n -> "fuzz/" ^ n ^ ".exe")
  in
  List.iter
    (fun flags ->
      Process.call ~env:(environment ())
        (Build.command ([ "build" ] @ flags @ [ "-j"; "4" ] @ names)))
    [ []; [ "--profile"; "fuzz"; "--build-dir"; build_dir ] ]

let entries directory kinds =
  files directory
  |> List.filter (fun p ->
      starts ~prefix:"id:" (Filename.basename p)
      && List.mem (Filename.basename (Filename.dirname p)) kinds)

let stats directory =
  let paths =
    files directory
    |> List.filter (fun p -> Filename.basename p = "fuzzer_stats")
  in
  require (List.length paths = 1) "Missing/ambiguous fuzzer statistics";
  read (List.hd paths)
  |> lines
  |> List.filter_map (fun line ->
      match String.index_opt line ':' with
      | None -> None
      | Some i ->
          Some
            ( String.trim (String.sub line 0 i),
              String.trim (String.sub line (i + 1) (String.length line - i - 1))
            ))

let count stats key =
  try int_of_string (List.assoc key stats)
  with _ -> fail "Invalid AFL statistic: %s" key

let execution_valid ~requested ~seconds ~executions =
  require
    (seconds >= max 1 (requested - 2) && executions >= 10)
    "Incomplete AFL campaign"

let run ?(extra = []) ?(flags = []) ~env ~seconds ~seeds ~output target =
  let env = List.fold_left (fun e (k, v) -> set e k v) env extra in
  let args =
    [
      afl / "afl-fuzz";
      "-V";
      string_of_int seconds;
      "-m";
      "512";
      "-t";
      "2000";
      "-i";
      seeds;
      "-o";
      output;
    ]
    @ flags
    @ [ "--"; binary target; "@@" ]
  in
  let r = Process.run ~env ~timeout:(float seconds +. 120.) ~check:false args in
  write (output ^ ".log") (r.stdout ^ r.stderr);
  require
    (Process.status_code r.status = 0)
    ("AFL failed; retained log/corpus: " ^ output)

let replay ?(limit = max_int) env target directory =
  let cases = entries directory [ "queue" ] |> List.sort String.compare in
  let rec take n xs =
    if n = 0 then []
    else match xs with [] -> [] | x :: xs -> x :: take (n - 1) xs
  in
  let cases = take limit cases in
  let logs =
    List.map
      (fun p ->
        let r = Process.run ~env ~timeout:5. [ plain target; p ] in
        r.stdout ^ r.stderr)
      cases
  in
  write (directory ^ "-replay.log") (String.concat "" logs);
  List.length cases

let campaign args =
  let requested = int_of_string (option args "--seconds" "30")
  and name = option args "--target" "all" in
  require (requested > 0) "Positive campaign duration required";
  let targets =
    json (root / "toolchain/fuzz-targets.json")
    |> list
    |> List.filter (fun t -> name = "all" || field "name" t = `String name)
  in
  require (targets <> []) "Unknown fuzz target";
  let digest = Build.source_hash () and revision = verify () in
  build (List.map (fun t -> string (field "binary" t)) targets);
  let directory =
    temp_dir
      ~parent:(root / "_artifacts/campaigns")
      (String.sub digest 0 12 ^ "-")
  in
  let rows =
    List.map
      (fun target ->
        let name = string (field "name" target)
        and target_binary = string (field "binary" target) in
        let env =
          match field "case" target with
          | `Null -> environment ()
          | case -> set (environment ()) "HTTP_KIT_FUZZ_CASE" (string case)
        in
        let seeds = directory / (name ^ "-seeds") in
        mkdir seeds;
        write (seeds / "valid") ("\000" ^ string (field "seed" target) ^ "\000");
        write (seeds / "controls") "\000\003\002\001\002\000";
        files (root / "fuzz/corpus" / name)
        |> List.filter (ends ~suffix:".seed")
        |> List.iter (fun p -> copy p (seeds / Filename.basename p));
        let output = directory / name and started = monotonic () in
        run ~env ~seconds:requested ~seeds ~output target_binary;
        let findings = entries output [ "crashes"; "hangs" ] in
        require (findings = [])
          ("Untriaged AFL findings retained: " ^ String.concat ", " findings);
        let stats = stats output in
        let seconds = count stats "run_time"
        and executions = count stats "execs_done" in
        execution_valid ~requested ~seconds ~executions;
        let replays = replay env target_binary output in
        require (replays > 0) "Empty replay corpus";
        let fields =
          [
            ("target", `String name);
            ("seconds_requested", `Int requested);
            ("seconds_executed", `Int seconds);
            ("wall_seconds", `Float (monotonic () -. started));
            ("executions", `Int executions);
            ("uninstrumented_replays", `Int replays);
            ("findings", `Int 0);
            ("directory", `String output);
          ]
        in
        require
          (Build.source_hash () = digest)
          "Sources changed during fuzz target";
        Build.record
          ("campaign-" ^ name ^ ".json")
          ([
             ("status", `String "PASS");
             ("compiler", `String Build.version);
             ("afl_revision", `String revision);
           ]
          @ fields);
        print_endline (Yojson.Basic.to_string (`Assoc fields));
        `Assoc fields)
      targets
  in
  require (Build.source_hash () = digest) "Sources changed during campaign";
  Build.record "campaign-summary.json"
    [
      ("status", `String "PASS");
      ("compiler", `String Build.version);
      ("afl_revision", `String revision);
      ("results", `List rows);
      ( "scope",
        `String (if requested >= 28800 then "release-duration" else "smoke") );
    ]

let smoke () =
  let digest = Build.source_hash ()
  and revision = verify ()
  and env = environment () in
  let out = root / "_artifacts/afl" in
  mkdir out;
  remove (out / "evidence.json");
  build
    [
      "instrumentation";
      "scenario_fuzz";
      "core_fuzz";
      "http1_fuzz";
      "engine_fuzz";
    ];
  let directory = temp_dir ~parent:out "run-" in
  let seeds = directory / "seeds" in
  mkdir seeds;
  write (seeds / "a") "A";
  write (directory / "b") "B";
  let maps =
    List.map
      (fun (name, p) ->
        let file = out / (name ^ ".map") in
        let r =
          Process.run ~env
            [
              afl / "afl-showmap";
              "-q";
              "-m";
              "512";
              "-o";
              file;
              "--";
              binary "instrumentation";
              p;
            ]
        in
        write (out / (name ^ "-map.log")) (r.stdout ^ r.stderr);
        read file)
      [ ("a", seeds / "a"); ("b", directory / "b") ]
  in
  require
    (List.for_all (( <> ) "") maps && List.nth maps 0 <> List.nth maps 1)
    "Instrumentation maps did not differ";
  let dictionary = directory / "dictionary" in
  write dictionary "fault=\"!\"\n";
  let planted target variable name =
    let output = directory / name in
    run ~env
      ~extra:[ (variable, "1") ]
      ~flags:[ "-x"; dictionary ] ~seconds:8 ~seeds ~output target;
    let crashes = entries output [ "crashes" ] in
    require (crashes <> []) "Planted fault was not discovered";
    let repro = out / (name ^ ".input") in
    copy (List.hd crashes) repro;
    let r =
      Process.run ~env:(set env variable "1") ~check:false
        [ plain target; repro ]
    in
    write (out / (name ^ "-replay.log")) (r.stdout ^ r.stderr);
    require (Process.status_code r.status = 2) "Planted failure did not replay"
  in
  planted "instrumentation" "HTTP_KIT_PLANTED_FAULT" "planted";
  write (seeds / "a") "\000abc\000";
  write (seeds / "b") "\001{}\000";
  planted "scenario_fuzz" "HTTP_KIT_CROWBAR_PLANTED_FAULT" "crowbar-planted";
  let check target name seconds =
    let output = directory / name in
    run ~env ~seconds ~seeds ~output target;
    let findings = entries output [ "crashes"; "hangs" ] in
    List.iteri
      (fun i p -> copy p (out / Printf.sprintf "%s-finding-%d.input" name i))
      findings;
    require (findings = []) ("Fuzz findings preserved: " ^ name);
    let stat = stats output in
    let executions = count stat "execs_done" in
    require (executions >= 10) "Insufficient fuzz executions";
    write
      (out / (name ^ "-stats.txt"))
      (String.concat "\n" (List.map (fun (k, v) -> k ^ ": " ^ v) stat));
    (executions, replay ~limit:32 env target output)
  in
  let harness_execs, _ = check "scenario_fuzz" "harness" 5 in
  let core_execs, _ = check "core_fuzz" "core" 5 in
  write (seeds / "request") "\000GET / HTTP/1.1\r\nHost: x\r\n\r\n\000";
  write (seeds / "response")
    "\001HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc\000";
  write (seeds / "chunked") "\0023\r\nabc\r\n0\r\n\r\n\000";
  let http1_execs, http1_replays = check "http1_fuzz" "http1" 10 in
  let engine_execs, engine_replays = check "engine_fuzz" "engine" 10 in
  require (Build.source_hash () = digest) "Sources changed during fuzz smoke";
  Build.record "afl/evidence.json"
    [
      ("status", `String "PASS");
      ("compiler", `String Build.version);
      ("afl_revision", `String revision);
      ("lock_directory", `String "dune.lock");
      ("coverage_maps_differ", `Bool true);
      ("planted_fault_found", `Bool true);
      ("uninstrumented_replay_failed_as_expected", `Bool true);
      ("crowbar_assertion_discovered_and_replayed", `Bool true);
      ("crowbar_execs", `Int harness_execs);
      ("core_execs", `Int core_execs);
      ("http1_execs", `Int http1_execs);
      ("engine_execs", `Int engine_execs);
      ("http1_uninstrumented_replays", `Int http1_replays);
      ("engine_uninstrumented_replays", `Int engine_replays);
      ( "scope",
        `String "Instrumentation and core/protocol/engine smoke budgets only" );
    ];
  print_endline "PASS AFL instrumentation and smoke controls"

let triage args =
  let replays = int_of_string (option args "--replays" "100")
  and seconds = int_of_string (option args "--afl-seconds" "30")
  and rounds = int_of_string (option args "--rounds" "3") in
  require
    (min replays (min seconds rounds) > 0)
    "Positive triage budgets required";
  let case = root / "fuzz/corpus/request/retained-timeout.seed" in
  let input = sha (read case) in
  require
    (input = "d8e43ca80ca7b49d20b83727a978efbf1b10eaabed29e0aeb2c2ff9ceabd3a3b")
    "Retained timeout input changed";
  let digest = Build.source_hash () and revision = verify () in
  build [ "http1_fuzz" ];
  let directory = temp_dir ~parent:(root / "_artifacts/personal") "timeout-" in
  let env = set (environment ()) "HTTP_KIT_FUZZ_CASE" "request" in
  let report =
    ref
      (`Assoc
         [
           ("source_sha256", `String digest);
           ("input_sha256", `String input);
           ("classification", `String "UNRESOLVED");
           ("afl_revision", `String revision);
           ("direct", `List []);
           ("afl", `List []);
           ("directory", `String directory);
         ])
  in
  let put key value = report := Benchmarks.setj key value !report in
  let append key value =
    put key (`List (list (field key !report) @ [ value ]))
  in
  let save_report () = save (directory / "report.json") !report in
  save_report ();
  try
    List.iter
      (fun (folder, exe) ->
        for i = 0 to replays - 1 do
          let start = monotonic () in
          let r = Process.run ~env ~timeout:2. ~check:false [ exe; case ] in
          append "direct"
            (`Assoc
               [
                 ("build", `String folder);
                 ("iteration", `Int i);
                 ("seconds", `Float (monotonic () -. start));
                 ("exit", `Int (Process.status_code r.status));
                 ("output", `String r.stdout);
               ]);
          save_report ();
          require
            (Process.status_code r.status = 0)
            "Direct timeout replay failed"
        done)
      [
        ("_build-pkg-5.5.0", plain "http1_fuzz");
        (build_dir, binary "http1_fuzz");
      ];
    let seeds = directory / "seeds" in
    mkdir seeds;
    copy case (seeds / "retained");
    for i = 0 to rounds - 1 do
      let output = directory / Printf.sprintf "round-%d" i in
      run ~env ~seconds ~seeds ~output
        ~flags:[ "-s"; string_of_int (42 + i) ]
        "http1_fuzz";
      let findings = entries output [ "hangs"; "crashes" ] in
      append "afl"
        (`Assoc
           [
             ("directory", `String output);
             ("exit", `Int 0);
             ("findings", strings findings);
           ]);
      save_report ();
      require (findings = []) "AFL triage finding retained"
    done;
    require (Build.source_hash () = digest) "Sources changed during triage";
    put "replay_status" (`String "PASS");
    put "interpretation"
      (`String
         "Not reproduced under direct execution or repeated original AFL \
          limits. Historical cause remains unproven.");
    save_report ();
    print_endline (directory / "report.json")
  with exn ->
    put "replay_status" (`String "FAIL");
    put "error" (`String (Printexc.to_string exn));
    save_report ();
    raise exn
