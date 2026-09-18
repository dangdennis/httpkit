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

let counters ~capacity app =
  let r = Framework.request app "GET" "/bench-stats" in
  require (r.status = 200) "Missing benchmark counters";
  let row = Yojson.Basic.from_string r.body in
  require
    (field "ocaml_version" row = `String Build.version
    && field "runtime" row = `String "eio"
    && field "max_connections" row = `Int capacity)
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

let concurrencies value =
  let values =
    String.split_on_char ',' value
    |> List.map (fun value ->
        require
          (value <> "" && String.for_all (fun c -> c >= '0' && c <= '9') value)
          "Concurrency must be a comma-separated list of integers in 1..64";
        int_of_string value)
  in
  require
    (List.length values <= 64
    && List.for_all (fun n -> n > 0 && n <= 64) values
    && List.length values = List.length (List.sort_uniq Int.compare values))
    "Concurrency must contain distinct integers in 1..64";
  values

let main args =
  let diagnostic = List.mem "--diagnostics" args in
  let concurrencies = concurrencies (option args "--concurrencies" "1,4,8") in
  let capacity = List.fold_left max 16 concurrencies in
  let rss_limit_kib = if capacity > 16 then 524288 else 262144 in
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
  let env =
    set
      (Build.measurement_environment ())
      "HTTPKIT_MAX_CONNECTIONS" (string_of_int capacity)
  in
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
           ("concurrencies", `List (List.map (fun n -> `Int n) concurrencies));
           ("max_connections", `Int capacity);
           ("rss_limit_kib", `Int rss_limit_kib);
           ("warmup_seconds_per_configuration", `Float 1.);
           ("keep_alive", `Bool true);
           ("diagnostic_run", `Bool diagnostic);
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
  let diagnostics =
    if diagnostic then Some (directory / "workers.json") else None
  in
  save_report ();
  try
    Framework.with_app ~env ~binary ~directory (fun app ->
        if diagnostic then (
          save
            (directory / "processes.json")
            (`Assoc
               [
                 ("client", `Int (Unix.getpid ()));
                 ("server", `Int app.child.pid);
                 ("port", `Int app.port);
               ]);
          Printf.printf "Endpoint diagnostics: %s\n%!" directory);
        Framework.exercise app;
        List.iter
          (fun case ->
            List.iter
              (fun concurrency ->
                ignore
                  (Load.epoch ?diagnostics ~port:app.port ~seconds:1.
                     ~concurrency ~rate:0. ~seed:42 ~modes:1 (operation case));
                for repetition = 1 to repetitions do
                  require
                    (Build.source_hash () = digest)
                    "Sources changed during endpoint profile";
                  let before = counters ~capacity app in
                  let epoch =
                    Load.epoch ?diagnostics ~port:app.port ~seconds ~concurrency
                      ~rate:0. ~seed:42 ~modes:1 (operation case)
                  in
                  require
                    (List.length (list (field "worker_operations" epoch))
                     = concurrency
                    && List.for_all
                         (fun n -> int n > 0)
                         (list (field "worker_operations" epoch)))
                    "Endpoint epoch did not exercise every concurrent worker";
                  let after = counters ~capacity app in
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
                    (Load.resources ~capacity app.port app.child.pid false);
                  Load.check_resources ~rss_limit_kib
                    (list (field "observations" !report));
                  save_report ();
                  Printf.printf
                    "Endpoint %s concurrency %d repetition %d/%d\n%!" case.name
                    concurrency repetition repetitions
                done)
              concurrencies)
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
