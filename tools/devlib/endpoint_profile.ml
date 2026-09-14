open Common

type case = {
  name : string;
  meth : string;
  path : string;
  body : string;
  expected : string;
}

let cases =
  [
    {
      name = "plaintext";
      meth = "GET";
      path = "/plaintext";
      body = "";
      expected = "Hello, world!\n";
    };
    {
      name = "json";
      meth = "GET";
      path = "/json";
      body = "";
      expected = {|{"message":"Hello, world!"}|};
    };
    {
      name = "echo";
      meth = "POST";
      path = "/echo";
      body = String.make 4096 'e';
      expected = String.make 4096 'e';
    };
    {
      name = "small-stream";
      meth = "GET";
      path = "/small-stream";
      body = "";
      expected = String.make 4096 's';
    };
    {
      name = "large-stream";
      meth = "GET";
      path = "/large-stream";
      body = "";
      expected = String.make 1048576 'x';
    };
  ]

let specification =
  `List
    (List.map
       (fun c ->
         `Assoc
           [
             ("name", `String c.name);
             ("method", `String c.meth);
             ("path", `String c.path);
             ("request_bytes", `Int (String.length c.body));
             ("response_bytes", `Int (String.length c.expected));
             ("request_sha256", `String (sha c.body));
             ("response_sha256", `String (sha c.expected));
           ])
       cases)

let operation case c _rng _mode =
  let response = Network.request ~body:case.body c case.meth case.path in
  require
    (response.status = 200 && response.body = case.expected)
    ("Endpoint payload mismatch: " ^ case.name);
  (case.name, String.length case.body + String.length case.expected)

let counters app =
  let r = Framework.request app "GET" "/bench-stats" in
  require (r.status = 200) "Missing benchmark counters";
  let row = Yojson.Basic.from_string r.body in
  require
    (field "ocaml_version" row = `String Build.version
    && field "runtime" row = `String "eio")
    "Unexpected endpoint server runtime/compiler";
  row

let summary ~operations ~seconds before after =
  require
    (operations > 0 && Float.is_finite seconds && seconds > 0.)
    "Invalid endpoint measurement";
  let delta key =
    let a = number (field key before) and b = number (field key after) in
    require
      (Float.is_finite a && Float.is_finite b && a >= 0. && b >= a)
      ("Invalid server counter: " ^ key);
    b -. a
  in
  let word_bytes = int (field "word_bytes" after) in
  require
    (List.mem word_bytes [ 4; 8 ]
    && field "word_bytes" before = field "word_bytes" after)
    "Invalid server word size";
  let words = delta "allocated_words" and cpu = delta "cpu_seconds" in
  `Assoc
    [
      ("allocated_words_per_request", `Float (words /. float operations));
      ( "allocated_bytes_per_request",
        `Float (words *. float word_bytes /. float operations) );
      ("minor_collections", `Float (delta "minor_collections"));
      ("major_collections", `Float (delta "major_collections"));
      ("cpu_seconds", `Float cpu);
      ("cpu_percent_one_core", `Float (100. *. cpu /. seconds));
    ]

let main args =
  let seconds = float_of_string (option args "--seconds" "10")
  and repetitions = int_of_string (option args "--repetitions" "3") in
  require
    (Float.is_finite seconds && seconds > 0. && seconds <= 3600.
   && repetitions > 0 && repetitions <= 100)
    "Invalid endpoint profile duration/repetitions";
  let binary = option args "--binary" "" in
  let profile = option args "--profile" "dev" in
  require
    (List.mem profile [ "dev"; "release" ])
    "Invalid endpoint build profile";
  require
    (binary = "" || not (List.mem "--profile" args))
    "An external binary cannot assert a build profile";
  let env = Build.measurement_environment () in
  let build_dir =
    if profile = "release" then "_build-bench-" ^ Build.version
    else "_build-pkg-" ^ Build.version
  in
  if binary = "" then
    Process.call ~env
      (Build.command
         [
           "build";
           "--profile=" ^ profile;
           "--build-dir=" ^ build_dir;
           "examples/framework/server.exe";
         ]);
  let binary =
    if binary = "" then
      root / build_dir / "default/examples/framework/server.exe"
    else absolute binary
  in
  let digest = Build.source_hash () in
  let directory =
    temp_dir ~parent:(root / "_artifacts/framework") "endpoints-"
  in
  let report =
    ref
      (`Assoc
         [
           ("status", `String "RUNNING");
           ("runtime", `String "eio");
           ( "build_profile",
             `String
               (if option args "--binary" "" = "" then profile
                else "external-unverified") );
           ( "server_environment",
             `String "OCaml tuning and instrumentation overrides cleared" );
           ( "client_runtime_tuning_present",
             `Bool
               (List.exists
                  (fun key -> Sys.getenv_opt key <> None)
                  [ "OCAMLRUNPARAM"; "CAMLRUNPARAM" ]) );
           ("source_sha256", `String digest);
           ("binary_sha256", `String (sha (read binary)));
           ( "workload_sha256",
             `String (sha (Yojson.Basic.to_string specification)) );
           ("workloads", specification);
           ("compiler", `String Build.version);
           ( "lock_metadata_sha256",
             `String (sha (read (root / "dune.lock/lock.dune"))) );
           ( "os_arch",
             `String
               (String.trim (Process.output ~timeout:5. [ "uname"; "-srm" ])) );
           ("available_domains", `Int (Domain.recommended_domain_count ()));
           ("seconds_requested", `Float seconds);
           ("repetitions", `Int repetitions);
           ("warmup_seconds_per_configuration", `Float 1.);
           ("keep_alive", `Bool true);
           ( "measurement_note",
             `String
               "Server counters include boundary sampling and connection \
                setup/teardown; client and server share the host. No forced GC \
                within counter intervals. Latencies are histogram upper \
                bounds." );
           ("epochs", `List []);
           ("observations", `List []);
         ])
  in
  let put key value = report := Benchmarks.setj key value !report in
  let append key value =
    put key (`List (list (field key !report) @ [ value ]))
  in
  let save_report () = save (directory / "report.json") !report in
  save_report ();
  try
    Framework.with_app ~env ~binary ~directory (fun app ->
        Framework.exercise app;
        List.iter
          (fun case ->
            List.iter
              (fun concurrency ->
                ignore
                  (Load.epoch ~port:app.port ~seconds:1. ~concurrency ~rate:0.
                     ~seed:42 ~modes:1 (operation case));
                for repetition = 1 to repetitions do
                  require
                    (Build.source_hash () = digest)
                    "Sources changed during endpoint profile";
                  let before = counters app in
                  let epoch =
                    Load.epoch ~port:app.port ~seconds ~concurrency ~rate:0.
                      ~seed:42 ~modes:1 (operation case)
                  in
                  let after = counters app in
                  let measured =
                    summary
                      ~operations:(int (field "operations" epoch))
                      ~seconds:(number (field "seconds" epoch))
                      before after
                  in
                  append "epochs"
                    (`Assoc
                       (("workload", `String case.name)
                       :: ("repetition", `Int repetition)
                       :: ("server", measured) :: assoc epoch));
                  append "observations"
                    (Load.resources app.port app.child.pid false);
                  Load.check_resources (list (field "observations" !report));
                  save_report ();
                  Printf.printf
                    "Endpoint %s concurrency %d repetition %d/%d\n%!" case.name
                    concurrency repetition repetitions
                done)
              [ 1; 4; 8 ])
          cases;
        Framework.close app;
        let final = Option.value ~default:`Null app.final in
        require
          (field "active" final = `Int 0
          && field "opened" final = field "closed" final
          && field "unexpected_errors" final = `Int 0)
          "Endpoint shutdown accounting";
        put "final" final);
    require
      (Build.source_hash () = digest)
      "Sources changed during endpoint final checks";
    put "status" (`String "PASS");
    save_report ();
    Printf.printf "PASS endpoint profile: %s\n%!" (directory / "report.json")
  with exn ->
    put "status" (`String "FAIL");
    put "error" (`String (Printexc.to_string exn));
    save_report ();
    raise exn
