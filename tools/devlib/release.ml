open Common

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

let compiler_valid data version =
  field "compiler" data = `String version
  && List.for_all (fun key -> field key data = `Bool true) consumers
  && field "odoc" data = `String "3.2.1"

let mutations_valid data =
  inventory (field "results" data) "name" mutants
  && List.for_all
       (fun row ->
         field "compiled" row = `Bool true
         && field "status" row = `String "KILLED")
       (list (field "results" data))

let campaign_valid data target seconds =
  field "target" data = `String target
  && (match field "seconds_executed" data with
    | `Int n -> n >= seconds
    | _ -> false)
  && field "findings" data = `Int 0
  &&
  match field "uninstrumented_replays" data with
  | `Int n -> n > 0
  | _ -> false

let assess directory expected policy targets license =
  let gates = ref [] in
  let add name ok detail =
    gates :=
      !gates
      @ [
          `Assoc
            [
              ("gate", `String name);
              ("status", `String (if ok then "PASS" else "NOT_READY"));
              ("detail", `String detail);
            ];
        ]
  in
  let evidence name =
    try
      let data = json (directory / (name ^ ".json")) in
      if
        field "source_sha256" data = `String expected
        && field "status" data = `String "PASS"
      then data
      else `Null
    with Sys_error _ | Yojson.Json_error _ -> `Null
  in
  List.iter
    (fun version ->
      add ("compiler/" ^ version)
        (compiler_valid (evidence ("compiler-" ^ version)) version)
        "Source-matched tests, docs and installed consumers.";
      add ("interop/" ^ version)
        (inventory
           (field "results" (evidence ("interop-" ^ version)))
           "lane" lanes)
        "Six direct/Nginx smoke lanes; extended reference evidence is separate.")
    [ "5.5.0" ];
  let data = evidence "afl/evidence" in
  add "instrumentation"
    (field "coverage_maps_differ" data = `Bool true
    && field "crowbar_assertion_discovered_and_replayed" data = `Bool true)
    "Coverage-map positive control and discovered/replayed planted failure.";
  add "curated-mutations"
    (mutations_valid (evidence "mutations-5.5.0"))
    "Compiled framing, ownership and output-accounting mutants must fail tests.";
  let data = evidence "coverage" in
  let percent =
    match field "percent" data with
    | `Int n -> float n
    | `Float n -> n
    | _ -> neg_infinity
  in
  add "point-coverage"
    (field "compiler" data = `String "5.5.0"
    && percent >= number (field "coverage_minimum_percent" policy)
    && field "missing_files" data = `List [])
    "At least 95% instrumented core/codec/engine points; this is not branch \
     coverage.";
  List.iter
    (fun name ->
      add ("fuzz/" ^ name)
        (campaign_valid
           (evidence ("campaign-" ^ name))
           name
           (int (field "fuzz_seconds_per_target" policy)))
        "Eight hours for this target, no untriaged findings, uninstrumented \
         corpus replay.")
    targets;
  let passed = list (field "passed" (evidence "platform-matrix")) in
  add "platform-matrix"
    (List.for_all
       (fun p -> List.mem p passed)
       (list (field "required_platforms" policy)))
    "Successful CI evidence for all declared platform/compiler pairs.";
  let nonempty key data =
    match field key data with
    | `Null | `String "" | `List [] | `Bool false -> false
    | _ -> true
  in
  List.iter
    (fun j ->
      let name = string j in
      let data = evidence name in
      add name
        (nonempty "reviewer" data && nonempty "review_url" data
        && field "approved" data = `Bool true
        && field "unresolved_findings" data = `List []
        && (name <> "security-review"
           || field "independent_of_implementation" data = `Bool true))
        "A real reviewer must supply source-matched findings and approval; \
         maintainer verifies identity and independence.")
    (list (field "required_reviews" policy));
  List.iter
    (fun j ->
      let name = string j in
      let data = evidence name in
      add name
        (nonempty "evidence_paths" data
        && nonempty "approved_by" data
        && field "unresolved_findings" data = `List [])
        "Reviewed source-matched evidence required; smoke results do not \
         substitute for this gate.")
    (list (field "required_extended_evidence" policy));
  add "license" license
    "Publication license must be chosen and committed by the owner.";
  let data = evidence "private-reporting" in
  add "private-reporting"
    (nonempty "verified_channel" data && nonempty "verified_by" data)
    "Verify the private vulnerability channel before a public release.";
  `Assoc
    [
      ("schema_version", `Int 1);
      ( "status",
        `String
          (if List.for_all (fun g -> field "status" g = `String "PASS") !gates
           then "READY"
           else "NOT_READY") );
      ("source_sha256", `String expected);
      ("gates", `List !gates);
    ]

let current () =
  assess (root / "_artifacts") (Build.source_hash ())
    (json (root / "toolchain/release-policy.json"))
    (json (root / "toolchain/fuzz-targets.json")
    |> list
    |> List.map (fun t -> string (field "name" t)))
    (Sys.file_exists (root / "LICENSE"))

let main args =
  let report = current () in
  let output = option args "--output" "" in
  if output <> "" then save (absolute output) report;
  print_endline (Yojson.Basic.pretty_to_string report);
  if field "status" report <> `String "READY" then exit 3
