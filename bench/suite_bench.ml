open Suite_support

let () =
  let family = ref "all"
  and quick = ref false
  and seed = ref 42
  and list_only = ref false in
  let external_suite = ref false in
  let preflight_only = ref false in
  let min_ms = ref 0. and case_filter = ref "" in
  let body_profile = ref "" and profile_iterations = ref 50 in
  Arg.parse
    [
      ( "--preflight-only",
        Arg.Set preflight_only,
        "Prepare selected cases and print eligible catalog" );
      ("--family", Arg.Set_string family, "Family to run");
      ( "--body-profile",
        Arg.Set_string body_profile,
        "Single diagnostic implementation/mode" );
      ( "--profile-iterations",
        Arg.Set_int profile_iterations,
        "Diagnostic repetitions" );
      ( "--min-ms",
        Arg.Set_float min_ms,
        "Minimum batch duration in milliseconds" );
      ("--case", Arg.Set_string case_filter, "Case id substring");
      ("--quick", Arg.Set quick, "Reduce iteration counts tenfold");
      ("--seed", Arg.Set_int seed, "Case order seed");
      ("--list", Arg.Set list_only, "Emit the workload catalog");
      ( "--external",
        Arg.Set external_suite,
        "Compare external libraries on shared workloads" );
    ]
    (fun _ -> raise (Arg.Bad "unexpected positional argument"))
    "HTTP toolkit benchmarks";
  if !body_profile <> "" then (
    Yojson.Basic.to_channel stdout
      (Suite_external_body.profile !body_profile !profile_iterations);
    print_newline ();
    exit 0);
  let select id = contains id !case_filter in
  let preflight = not !list_only in
  let families =
    if !external_suite then
      [
        ("router", Suite_external_router.jobs);
        ("http1", Suite_external_http1.jobs);
        ("body", fun () -> Suite_external_body.jobs ~select ~preflight ());
        ("exchange", fun () -> Suite_exchange.jobs ~select ~preflight ());
        ( "router-experiment",
          fun () -> Suite_router_experiment.jobs ~preflight () );
      ]
    else
      [
        ("core", Suite_core.jobs);
        ("router", Suite_router.jobs);
        ("http1", Suite_http1.jobs);
        ("middleware", Suite_middleware.jobs);
        ("engine", Suite_engine.jobs);
      ]
  in
  if !family <> "all" && not (List.mem_assoc !family families) then
    failwith "unknown benchmark family";
  let jobs =
    List.concat_map
      (fun (name, build) ->
        if !family = "all" || !family = name then build () else [])
      families
  in
  if (not (Float.is_finite !min_ms)) || !min_ms < 0. || !min_ms > 1000. then
    failwith "invalid minimum duration";
  let jobs = List.filter (fun job -> contains job.id !case_filter) jobs in
  if jobs = [] then failwith "empty case selection";
  let results =
    if !list_only || !preflight_only then
      List.map
        (fun job ->
          `Assoc
            (labels job
            @ [
                ("id", `String job.id);
                ("family", `String job.family);
                ( "iterations",
                  `Int
                    (if !quick then max 1 (job.iterations / 10)
                     else job.iterations) );
                ("bytes_per_op", `Int job.bytes);
              ]))
        jobs
    else
      let jobs = Array.of_list jobs in
      let rng = Random.State.make [| !seed |] in
      for i = Array.length jobs - 1 downto 1 do
        let j = Random.State.int rng (i + 1) in
        let tmp = jobs.(i) in
        jobs.(i) <- jobs.(j);
        jobs.(j) <- tmp
      done;
      Array.to_list
        (Array.map
           (fun job ->
             try measure ~quick:!quick ~min_ms:!min_ms job
             with exn -> failwith (job.id ^ ": " ^ Printexc.to_string exn))
           jobs)
  in
  Yojson.Basic.to_channel stdout
    (`Assoc
       [
         ("schema", `Int 1);
         ("compiler", `String Sys.ocaml_version);
         ("quick", `Bool !quick);
         ("min_ms", `Float !min_ms);
         ("seed", `Int !seed);
         ("results", `List results);
         ("exclusions", `List (List.rev !exclusions));
       ]);
  print_newline ()
