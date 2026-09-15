open Common

type profile = Beta | Production

let profile_name = function Beta -> "beta" | Production -> "production"

let ready_status = function
  | Beta -> "BETA_READY"
  | Production -> "PRODUCTION_READY"

let consumers =
  [
    "core_consumer";
    "http1_consumer";
    "engine_consumer";
    "adapter_consumer";
    "middleware_consumer";
    "router_consumer";
    "routing_examples";
  ]

let mutants = [ "framing-cl-te"; "foreign-request-id"; "output-accounting" ]

let framework_mutants =
  [
    "cookie-secure-default";
    "multipart-quota";
    "session-expiry";
    "request-lifetime";
  ]

let platforms = [ "linux-x86_64/5.5.0"; "macos-arm64/5.5.0" ]
let reviews = [ "security-review"; "api-review" ]

let campaigns =
  [
    "internal-review";
    "reference-differential";
    "proxy-observers";
    "stable-performance";
    "soak";
    "contract-coverage";
    "dependencies";
    "packaging";
  ]

let features =
  [
    "http1";
    "engine";
    "eio";
    "lwt";
    "routing-middleware";
    "json-forms";
    "streaming-sse";
    "static";
    "uploads";
    "cookies-sessions";
    "database";
    "password";
    "oidc";
  ]

let fuzz_targets =
  [
    "core";
    "request";
    "response";
    "chunked";
    "server";
    "client";
    "partial-write";
    "adapter";
    "isolation";
    "url";
    "forms";
    "router";
    "multipart";
    "websocket";
  ]

let lanes =
  List.concat_map
    (fun runtime ->
      List.map
        (fun lane -> runtime ^ "/" ^ lane)
        [ "direct"; "nginx-buffering-on"; "nginx-buffering-off" ])
    [ "eio"; "lwt" ]

let inventory rows key expected =
  match rows with
  | `List rows ->
      List.length rows = List.length expected
      && List.sort compare (List.map (field key) rows)
         = List.sort compare (List.map (fun s -> `String s) expected)
  | _ -> false

let nonempty = function `String s -> String.trim s <> "" | _ -> false

let string_list = function
  | `List (_ :: _ as xs) -> List.for_all nonempty xs
  | _ -> false

let rec unique_json = function
  | `Assoc fields ->
      let keys = List.map fst fields in
      List.length keys = List.length (List.sort_uniq String.compare keys)
      && List.for_all (fun (_, value) -> unique_json value) fields
  | `List xs -> List.for_all unique_json xs
  | _ -> true

(* Manifests cannot redirect reads outside their directory or block on a FIFO. *)
let read_evidence directory path =
  require (Filename.is_relative path) "Absolute evidence path";
  require
    (not (List.mem ".." (String.split_on_char '/' path)))
    "Parent evidence path";
  let path = Unix.realpath (directory / path) in
  require
    (starts ~prefix:(Unix.realpath directory ^ "/") path)
    "Evidence escapes directory";
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  let ic = Unix.in_channel_of_descr fd in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let stat = Unix.fstat fd in
      require
        (stat.st_kind = Unix.S_REG && stat.st_size <= 16777216)
        "Evidence must be a regular file of at most 16 MiB";
      let bytes = really_input_string ic stat.st_size in
      (match input_char ic with
      | _ -> fail "Evidence grew while reading"
      | exception End_of_file -> ());
      bytes)

let compiler_valid data =
  field "compiler" data = `String "5.5.0"
  && List.for_all
       (fun key -> field key data = `Bool true)
       (consumers
       @ [ "framework_consumer"; "extension_consumer"; "framework_integration" ]
       )

let mutations_valid expected data =
  inventory (field "results" data) "name" expected
  && List.for_all
       (fun row ->
         field "compiled" row = `Bool true
         && field "status" row = `String "KILLED")
       (list (field "results" data))

let coverage_valid minimum data =
  let visited = int (field "visited" data)
  and total = int (field "total" data) in
  let percent = number (field "percent" data) in
  total > 0 && visited >= 0 && visited <= total && Float.is_finite percent
  && abs_float (percent -. (100. *. float visited /. float total)) < 0.000001
  && percent >= minimum && percent <= 100.
  && field "missing_files" data = `List []
  && field "critical_paths_reviewed" data = `Bool true
  && field "metric" data = `String "instrumented points, not branches"

let native_valid policy target data =
  let rows = list (field "runs" data) in
  let checked = List.map (fun r -> int (field "checked" r)) rows in
  let seconds = List.map (fun r -> number (field "seconds" r)) rows in
  let seeds =
    List.map
      (fun r ->
        let value = Int64.of_string (string (field "seed" r)) in
        require (value >= 0L) "Negative seed";
        Int64.to_string value)
      rows
  in
  field "target" data = `String target
  && field "mode" data = `String "NATIVE"
  && field "unresolved_findings" data = `List []
  && field "regression_inventory_replayed" data = `Bool true
  && field "negative_controls_passed" data = `Bool true
  && rows <> []
  && List.for_all (( < ) 0) checked
  && List.for_all (fun n -> Float.is_finite n && n >= 0.) seconds
  && List.for_all
       (fun r ->
         field "status" r = `String "PASS"
         && field "exit" r = `Int 0
         && field "failed" r = `Int 0
         && field "timing_scope" r = `String "child_campaign"
         && int (field "skipped" r) >= 0
         && int (field "checked" r) <= int (field "generated" r)
         && int (field "skipped" r)
            = int (field "generated" r) - int (field "checked" r)
         && nonempty (field "binary_sha256" r))
       rows
  && List.length seeds = List.length (List.sort_uniq String.compare seeds)
  && List.length seeds >= int (field "native_seeds_per_target" policy)
  && List.fold_left (fun n i -> n +. float i) 0. checked
     >= number (field "native_checked_per_target" policy)
  && List.fold_left ( +. ) 0. seconds
     >= number (field "native_seconds_per_target" policy)

let assess ?(profile = Production) ~clean ~candidate ~lock_sha256 directory
    expected policy targets license =
  let gates = ref [] in
  let safe check =
    try check ()
    with
    | Error _ | Sys_error _ | Unix.Unix_error _ | Yojson.Json_error _
    | End_of_file | Invalid_argument _ | Failure _
    ->
      false
  in
  let add ?(required = true) name check detail =
    let ok = safe check in
    gates :=
      !gates
      @ [
          `Assoc
            [
              ("gate", `String name);
              ("required", `Bool required);
              ( "status",
                `String
                  (if ok then "PASS"
                   else if required then "NOT_READY"
                   else "PENDING") );
              ("detail", `String detail);
            ];
        ]
  in
  let manifest =
    try
      let j =
        Yojson.Basic.from_string
          (read_evidence directory "release-manifest.json")
      in
      require (unique_json j) "Duplicate manifest key";
      j
    with
    | Error _ | Sys_error _ | Unix.Unix_error _ | Yojson.Json_error _
    | End_of_file
    ->
      `Null
  in
  let entries = list (field "reports" manifest) in
  let manifest_valid () =
    field "schema_version" manifest = `Int 2
    && field "source_sha256" manifest = `String expected
    && field "candidate_commit" manifest = `String candidate
    && candidate <> ""
    && field "lock_sha256" manifest = `String lock_sha256
    && lock_sha256 <> ""
    && field "compiler" manifest = `String "5.5.0"
    && entries <> []
    &&
    let names = List.map (fun row -> string (field "name" row)) entries in
    List.length names = List.length (List.sort_uniq String.compare names)
  in
  let attachment row =
    let bytes = read_evidence directory (string (field "path" row)) in
    require
      (field "sha256" row = `String (sha bytes))
      "Evidence digest mismatch";
    bytes
  in
  let evidence name =
    require (manifest_valid ()) "Invalid manifest";
    let row =
      match List.find_opt (fun r -> field "name" r = `String name) entries with
      | Some r -> r
      | None -> fail "Missing evidence %s" name
    in
    require
      (nonempty (field "platform" row) && string_list (field "command" row))
      "Missing evidence provenance";
    let data = Yojson.Basic.from_string (attachment row) in
    require
      (unique_json data
      && field "status" data = `String "PASS"
      && field "source_sha256" data = `String expected)
      "Invalid report";
    let supporting = list (field "attachments" row) in
    require (supporting <> []) "Missing underlying evidence";
    List.iter (fun r -> ignore (attachment r)) supporting;
    data
  in
  add "policy"
    (fun () ->
      field "schema_version" policy = `Int 2
      && unique_json policy
      && Float.is_finite (number (field "native_seconds_per_target" policy))
      && number (field "native_seconds_per_target" policy) >= 1800.
      && int (field "native_checked_per_target" policy) >= 100000
      && int (field "native_seeds_per_target" policy) >= 20
      && List.sort String.compare targets
         = List.sort String.compare fuzz_targets)
    "Versioned native budgets and full target inventory; weakened or missing \
     policy cannot pass.";
  add "manifest" manifest_valid
    "Candidate, source, locks and report identities must match.";
  add "frozen-checkout"
    (fun () -> clean)
    "Commit all candidate source changes before collecting release evidence.";
  List.iter
    (fun platform ->
      add ("platform/" ^ platform)
        (fun () ->
          let d = evidence ("compiler/" ^ platform) in
          compiler_valid d
          && field "platform" d = `String platform
          && field "execution" d = `String "LOCAL")
        "Local build, docs, tests and installed native/bytecode consumers.")
    platforms;
  add "interop"
    (fun () -> inventory (field "results" (evidence "interop")) "lane" lanes)
    "Six direct/Nginx controls; live staging is a separate gate.";
  List.iter
    (fun (name, expected) ->
      add name
        (fun () -> mutations_valid expected (evidence name))
        "Every curated mutant compiles and fails a regression.")
    [ ("mutations", mutants); ("framework-mutations", framework_mutants) ];
  List.iter
    (fun (name, threshold) ->
      add ("coverage/" ^ name)
        (fun () ->
          let configured =
            number (field name (field "coverage_minimum_percent" policy))
          in
          Float.is_finite configured && configured >= threshold
          && configured <= 100.
          && coverage_valid configured (evidence ("coverage/" ^ name)))
        "Measured points and critical-path review; not a security percentage.")
    [ ("core", 95.); ("framework", 85.); ("extensions", 80.) ];
  List.iter
    (fun target ->
      add ("native/" ^ target)
        (fun () -> native_valid policy target (evidence ("native/" ^ target)))
        "Completed native batches, distinct seeds, checked inputs, replay and \
         failure controls.")
    fuzz_targets;
  List.iter
    (fun name ->
      add name
        (fun () ->
          let d = evidence name in
          nonempty (field "reviewed_by" d)
          && field "unresolved_findings" d = `List []
          && field "acceptance_passed" d = `Bool true)
        "Retained feature-specific measurements and internal acceptance review.")
    campaigns;
  add "support-scope"
    (fun () ->
      let d = evidence "support-scope" in
      inventory (field "features" d) "name" features
      && List.for_all
           (fun r -> field "status" r = `String "BETA_TESTED")
           (list (field "features" d))
      && field "websocket" d = `String "EXPERIMENTAL"
      && field "public_production_claim" d = `Bool false)
    "Tested beta scope is explicit; WebSockets remain experimental in both \
     profiles.";
  List.iter
    (fun name ->
      add ~required:(profile = Production) name
        (fun () ->
          let d = evidence name in
          nonempty (field "reviewer" d)
          && field "approved" d = `Bool true
          && field "unresolved_findings" d = `List []
          && field "independent_of_implementation" d = `Bool true
          && nonempty (field "identity_verified_by" d))
        "Independent review remains pending for beta; owner verifies identity \
         and contents.")
    reviews;
  add "license"
    (fun () -> license)
    "Owner-approved project license must be committed.";
  add "private-reporting"
    (fun () ->
      let d = evidence "private-reporting" in
      nonempty (field "verified_channel" d) && nonempty (field "verified_by" d))
    "Verified private vulnerability-reporting channel.";
  let ready =
    List.for_all
      (fun g ->
        field "required" g = `Bool false || field "status" g = `String "PASS")
      !gates
  in
  `Assoc
    [
      ("schema_version", `Int 2);
      ("profile", `String (profile_name profile));
      ("status", `String (if ready then ready_status profile else "NOT_READY"));
      ("source_sha256", `String expected);
      ("candidate_commit", `String candidate);
      ("afl", `String "REPLACED_BY_NATIVE_POLICY");
      ("hosted_ci", `String "UNAVAILABLE_NOT_EVALUATED");
      ("websocket", `String "EXPERIMENTAL");
      ("gates", `List !gates);
    ]

let lock_hash () =
  files (root / "dune.lock") @ files (root / "coverage.lock")
  |> List.sort String.compare
  |> List.map (fun p ->
      String.sub p
        (String.length root + 1)
        (String.length p - String.length root - 1)
      ^ "\000" ^ read p ^ "\000")
  |> String.concat "" |> sha

let current ?(profile = Production) () =
  assess ~profile
    ~clean:
      (String.trim
         (Process.output
            [ "git"; "status"; "--porcelain"; "--untracked-files=normal" ])
      = "")
    ~candidate:(String.trim (Process.output [ "git"; "rev-parse"; "HEAD" ]))
    ~lock_sha256:(lock_hash ()) (root / "_artifacts") (Build.source_hash ())
    (json (root / "toolchain/release-policy.json"))
    (json (root / "toolchain/fuzz-targets.json")
    |> list
    |> List.map (fun t -> string (field "name" t)))
    (Sys.file_exists (root / "LICENSE"))

let main args =
  let profile =
    match option args "--profile" "production" with
    | "beta" -> Beta
    | "production" -> Production
    | _ -> fail "Unknown release profile"
  in
  let report = current ~profile () in
  let output = option args "--output" "" in
  if output <> "" then save (absolute output) report;
  print_endline (Yojson.Basic.pretty_to_string report);
  if field "status" report <> `String (ready_status profile) then exit 3
