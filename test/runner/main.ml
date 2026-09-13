open Harness

let output json =
  Yojson.Safe.pretty_to_channel stdout json;
  print_newline ()

let die status message =
  output (`Assoc [ ("status", `String status); ("message", `String message) ]);
  exit (if status = "INFRA_ERROR" then 2 else 3)

let option args name default =
  let rec find = function
    | [] -> default
    | k :: v :: _ when k = name -> v
    | [ k ] when k = name -> die "INFRA_ERROR" ("missing " ^ name)
    | _ :: rest -> find rest
  in
  find args

let allowed args flags =
  let rec check = function
    | [] -> ()
    | k :: _ when not (List.mem k flags) ->
        die "INFRA_ERROR" ("unknown option " ^ k)
    | [ _ ] -> die "INFRA_ERROR" "missing option value"
    | _ :: _ :: rest -> check rest
  in
  check args

let positive name value =
  match int_of_string_opt value with
  | Some n when n > 0 && n <= 100000 -> n
  | _ -> die "INFRA_ERROR" ("invalid " ^ name)

let write_json path json =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      Yojson.Safe.pretty_to_channel oc json;
      output_char oc '\n')

let xml s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         match s.[i] with
         | '&' -> "&amp;"
         | '<' -> "&lt;"
         | '>' -> "&gt;"
         | '"' -> "&quot;"
         | c -> String.make 1 c))

let run_cases ?(scope = "M1 synthetic harness only") ~count ~seed cases =
  let results =
    List.map
      (fun (name, test) ->
        let start = Harness_runtime.Watchdog.now () in
        let error =
          try
            test ();
            None
          with exn -> Some (Printexc.to_string exn)
        in
        (name, error, Harness_runtime.Watchdog.now () -. start))
      cases
  in
  let failures = List.filter (fun (_, e, _) -> e <> None) results in
  let json =
    `Assoc
      [
        ("status", `String (if failures = [] then "PASS" else "FAIL"));
        ("scope", `String scope);
        ("seed", `Int seed);
        ("cases_per_property", `Int count);
        ("executed", `Int (List.length results));
        ( "results",
          `List
            (List.map
               (fun (name, error, seconds) ->
                 `Assoc
                   [
                     ("case", `String name);
                     ("seconds", `Float seconds);
                     ( "status",
                       `String (if error = None then "PASS" else "FAIL") );
                     ( "error",
                       match error with None -> `Null | Some e -> `String e );
                   ])
               results) );
        ( "pending_release_capabilities",
          `List (List.map (fun x -> `String x) Registry.pending_capabilities) );
      ]
  in
  (json, results, failures = [])

let report_files args json results =
  let file = option args "--report" "" in
  if file <> "" then write_json file json;
  let file = option args "--junit" "" in
  if file <> "" then
    let oc = open_out_bin file in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
        Printf.fprintf oc
          "<testsuite name=\"httpkit-harness\" tests=\"%d\" failures=\"%d\">\n"
          (List.length results)
          (List.length (List.filter (fun (_, e, _) -> e <> None) results));
        List.iter
          (fun (name, error, seconds) ->
            Printf.fprintf oc "<testcase name=\"%s\" time=\"%.6f\">" (xml name)
              seconds;
            Option.iter
              (fun e -> Printf.fprintf oc "<failure message=\"%s\"/>" (xml e))
              error;
            output_string oc "</testcase>\n")
          results;
        output_string oc "</testsuite>\n")

let load path =
  match Scenario.load path with Ok s -> s | Error e -> die "INFRA_ERROR" e

let subject args =
  match Contract.fault_of_string (option args "--subject" "correct") with
  | Ok s -> s
  | Error e -> die "INFRA_ERROR" e

let read_command prog argv =
  try
    let ic = Unix.open_process_args_in prog argv in
    let b = Buffer.create 128 in
    (try
       while true do
         Buffer.add_string b (input_line ic);
         Buffer.add_char b '\n'
       done
     with End_of_file -> ());
    let status = Unix.close_process_in ic in
    if status = Unix.WEXITED 0 then `String (String.trim (Buffer.contents b))
    else `Null
  with Unix.Unix_error _ -> `Null

let provenance () =
  `Assoc
    [
      ("compiler", `String Sys.ocaml_version);
      ("executable", `String Sys.executable_name);
      ("source", `String (Devlib.Build.source_hash ()));
      ( "packages",
        `String
          (Yojson.Basic.to_string
             (`Assoc
                [
                  ("lock_directory", `String "dune.lock");
                  ("packages", Devlib.Build.locked_packages ());
                ])) );
    ]

let main () =
  match Array.to_list Sys.argv |> List.tl with
  | [ "doctor" ] ->
      output
        (`Assoc
           [
             ("status", `String "INFO");
             ("ocaml", `String Sys.ocaml_version);
             ("dune", read_command "dune" [| "dune"; "--version" |]);
             ("cwd", `String (Sys.getcwd ()));
             ( "scope",
               `String
                 "harness only; run tools/dev evidence check for \
                  source-matched M0 evidence" );
             ( "coverage_evidence",
               `Bool (Sys.file_exists "_artifacts/afl/evidence.json") );
             ("registry", Registry.to_json ());
           ])
  | [ "registry" ] -> output (Registry.to_json ())
  | "run" :: args ->
      allowed args
        [ "--tier"; "--suite"; "--seed"; "--count"; "--report"; "--junit" ];
      let tier = option args "--tier" "fast"
      and suite = option args "--suite" "all" in
      if tier <> "fast" then
        die "NOT_IMPLEMENTED" ("tier not implemented: " ^ tier);
      if
        not
          (List.mem suite
             [ "all"; "self"; "property"; "core"; "http1"; "engine" ])
      then die "NOT_IMPLEMENTED" ("suite not implemented: " ^ suite);
      let count = positive "count" (option args "--count" "200") in
      let seed =
        match int_of_string_opt (option args "--seed" "42") with
        | Some n -> n
        | None -> die "INFRA_ERROR" "invalid seed"
      in
      let cases =
        (if suite = "all" || suite = "self" then Self_cases.cases else [])
        @ (if suite = "all" || suite = "property" then
             Self_cases.properties ~seed ~count
           else [])
        @
        if suite = "all" || suite = "core" then
          Core_cases.cases @ Core_cases.properties ~seed ~count
        else []
      in
      let cases =
        cases
        @
        if suite = "all" || suite = "http1" then
          Http1_cases.cases @ Http1_cases.properties ~seed ~count
        else []
      in
      let cases =
        cases
        @
        if suite = "all" || suite = "engine" then
          Engine_cases.cases @ Engine_cases.properties ~seed ~count
        else []
      in
      let scope =
        if suite = "engine" then "M4 sans-I/O engines"
        else if suite = "http1" then "M3 HTTP/1 codecs"
        else if suite = "core" then "M2 core values"
        else if suite = "all" then
          "M1 synthetic harness, M2 core values M3 HTTP/1 codecs and M4 engines"
        else "M1 synthetic harness only"
      in
      let json, results, ok = run_cases ~scope ~count ~seed cases in
      report_files args json results;
      output json;
      if not ok then exit 1
  | "replay" :: path :: args ->
      allowed args [ "--subject"; "--report" ];
      let fault = subject args and s = load path in
      let report = Runner.run fault s in
      let json =
        `Assoc
          [
            ("subject", `String (Contract.fault_name fault));
            ("provenance", provenance ());
            ("scenario", Scenario.to_json s);
            ("result", Runner.to_json report);
          ]
      in
      let file = option args "--report" "" in
      if file <> "" then write_json file json;
      output json;
      if report.failure <> None then exit 1
  | "shrink" :: path :: args ->
      allowed args [ "--subject"; "--output"; "--report" ];
      let fault = subject args and s = load path in
      if (Runner.run fault s).failure = None then
        die "INFRA_ERROR" "cannot shrink a passing scenario";
      let deadline = Harness_runtime.Watchdog.now () +. 60. in
      let result =
        Shrink.minimize
          ~expired:(fun () -> Harness_runtime.Watchdog.now () >= deadline)
          fault s
      in
      let file = option args "--output" (path ^ ".min.json") in
      (if Sys.file_exists file then
         let input_stat = Unix.stat path and output_stat = Unix.stat file in
         if
           input_stat.st_dev = output_stat.st_dev
           && input_stat.st_ino = output_stat.st_ino
         then
           die "INFRA_ERROR"
             "shrink output must not overwrite the original scenario");
      Scenario.save file result.scenario;
      let json =
        `Assoc
          [
            ("status", `String "SHRUNK_FAILURE");
            ("output", `String file);
            ("subject", `String (Contract.fault_name fault));
            ("provenance", provenance ());
            ("attempts", `Int result.attempts);
            ("budget_exhausted", `Bool result.exhausted);
            ("original", Scenario.to_json s);
            ("minimized", Scenario.to_json result.scenario);
            ("result", Runner.to_json (Runner.run fault result.scenario));
          ]
      in
      let file = option args "--report" "" in
      if file <> "" then write_json file json;
      output json
  | [ "example"; name; path ] ->
      let s =
        if name = "happy" then Fixtures.happy
        else
          match Contract.fault_of_string name with
          | Ok f -> Fixtures.fault_case f
          | Error e -> die "INFRA_ERROR" e
      in
      Scenario.save path s;
      output (`Assoc [ ("status", `String "WRITTEN"); ("path", `String path) ])
  | [ "readiness"; "--release" ] | [ "readiness"; "--milestone"; "M7" ] ->
      (* Release assessment checks retained evidence; it never starts campaigns
         or invents missing reviews. Preserve its incomplete-scope exit code. *)
      Devlib.Release.main []
  | [ "readiness"; "--milestone"; "M1" ] ->
      let json, _, ok =
        run_cases ~count:200 ~seed:42
          (Self_cases.cases @ Self_cases.properties ~seed:42 ~count:200)
      in
      output json;
      if not ok then exit 1
  | [
   "readiness";
   "--milestone";
   (("M0" | "M2" | "M3" | "M4" | "M5" | "M6") as milestone);
  ] ->
      Devlib.Evidence.check milestone
  | "readiness" :: _ -> die "NOT_IMPLEMENTED" "milestone unavailable"
  | ("fuzz" | "bench" | "compare") :: _ ->
      die "NOT_IMPLEMENTED"
        "use tools/fuzz-smoke for M0 instrumentation; protocol/performance \
         targets are pending"
  | _ ->
      die "INFRA_ERROR"
        "usage: httpkit-test \
         doctor|registry|run|replay|shrink|example|readiness (see README)"

let () =
  Printexc.record_backtrace true;
  try main () with exn -> die "INFRA_ERROR" (Printexc.to_string exn)
