open Suite_support

let () =
  let family = ref "all"
  and quick = ref false
  and seed = ref 42
  and list_only = ref false in
  Arg.parse
    [
      ("--family", Arg.Set_string family, "Family to run");
      ("--quick", Arg.Set quick, "Reduce iteration counts tenfold");
      ("--seed", Arg.Set_int seed, "Case order seed");
      ("--list", Arg.Set list_only, "Emit the workload catalog");
    ]
    (fun _ -> raise (Arg.Bad "unexpected positional argument"))
    "HTTP toolkit benchmarks";
  let families =
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
  let results =
    if !list_only then
      List.map
        (fun job ->
          `Assoc
            [
              ("id", `String job.id);
              ("family", `String job.family);
              ( "iterations",
                `Int
                  (if !quick then max 1 (job.iterations / 10)
                   else job.iterations) );
              ("bytes_per_op", `Int job.bytes);
            ])
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
             try measure ~quick:!quick job
             with exn -> failwith (job.id ^ ": " ^ Printexc.to_string exn))
           jobs)
  in
  Yojson.Basic.to_channel stdout
    (`Assoc
       [
         ("schema", `Int 1);
         ("compiler", `String Sys.ocaml_version);
         ("quick", `Bool !quick);
         ("seed", `Int !seed);
         ("results", `List results);
       ]);
  print_newline ()
