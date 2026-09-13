open Common
open Benchmarks

let reject f =
  require (Selftest.rejects f) "Invalid benchmark evidence accepted"

let map_first f = function x :: xs -> f x :: xs | [] -> fail "Missing fixture"

let rows f sample =
  setj "results" (`List (f (list (field "results" sample)))) sample

let main () =
  let catalog =
    [
      `Assoc
        [
          ("id", `String "router/test");
          ("family", `String "router");
          ("iterations", `Int 10);
          ("bytes_per_op", `Int 0);
        ];
    ]
  in
  let measurement row ns =
    `Assoc
      (assoc row
      @ [
          ("warmups", `Int 3);
          ("elapsed_ns", `Float (ns *. 10.));
          ("ns_per_op", `Float ns);
          ("allocated_bytes_per_op", `Int 0);
          ("minor_collections", `Int 0);
          ("major_collections", `Int 0);
        ])
  in
  let sample seed result =
    `Assoc
      [
        ("schema", `Int 1);
        ("compiler", `String "5.5.0");
        ("quick", `Bool false);
        ("seed", `Int seed);
        ("results", `List result);
      ]
  in
  let samples =
    List.mapi
      (fun i ns -> sample (42 + i) [ measurement (List.hd catalog) ns ])
      [ 10.; 20.; 30. ]
  in
  let build samples =
    `Assoc
      [
        ("schema", `Int 1);
        ("compiler", `String "5.5.0");
        ("profile", `String "release");
        ("workload_sha256", `String "workload");
        ("source_sha256", `String "source");
        ("host_fingerprint", `String "host");
        ( "config",
          `Assoc
            [
              ("quick", `Bool false);
              ("family", `String "router");
              ("samples", `Int 3);
              ("seeds", `List [ `Int 42; `Int 43; `Int 44 ]);
            ] );
        ("catalog", `List catalog);
        ("samples", `List samples);
        ("results", `List (aggregate samples catalog "5.5.0" false));
      ]
  in
  let report = build samples in
  validate_report report;
  let row = List.hd (list (field "results" report)) in
  require
    (getn "median_ns_per_op" row = 20.
    && getn "min_ns_per_op" row = 10.
    && getn "max_ns_per_op" row = 30.
    && getn "coefficient_of_variation" row = 0.5
    && field "payload_mib_per_second" row = `Null)
    "Median/spread fixture";
  require
    (field "median_bootstrap_95_ns" row = `List [ `Float 10.; `Float 30. ]
    && field "timing_quality" row = `String "noisy")
    "Bootstrap interval/quality";
  require
    (sample_timeout 1 0. = 600. && sample_timeout 844 1000. > 1688.)
    "Sample budget";
  List.iter
    (fun (n, ms) -> reject (fun () -> ignore (sample_timeout n ms)))
    [ (2000, 1000.); (0, 0.); (1, nan); (1, 1001.) ];
  let calibrated =
    List.map
      (rows
         (List.map (fun row ->
              row
              |> setj "base_iterations" (`Int 10)
              |> setj "iterations" (`Int 100)
              |> setj "elapsed_ns" (`Float (getn "ns_per_op" row *. 100.)))))
      samples
  in
  ignore (build calibrated);
  reject (fun () ->
      ignore
        (build
           (map_first
              (rows (map_first (setj "base_iterations" (`Int 101))))
              calibrated)));
  let short = List.map (setj "min_ms" (`Int 50)) samples in
  require
    (field "timing_quality" (List.hd (aggregate short catalog "5.5.0" false))
    = `String "short-batch")
    "Short-batch quality";
  List.iter
    (fun ms ->
      reject (fun () ->
          ignore (build (map_first (setj "min_ms" (`Float ms)) samples))))
    [ -1.; nan; infinity; 1001. ];
  let byte_catalog = List.map (setj "bytes_per_op" (`Int 1048576)) catalog in
  let byte_samples =
    List.map (rows (List.map (setj "bytes_per_op" (`Int 1048576)))) samples
  in
  require
    (getn "payload_mib_per_second"
       (List.hd (aggregate byte_samples byte_catalog "5.5.0" false))
    = 50000000.)
    "Byte throughput";
  List.iter
    (fun c -> reject (fun () -> ignore (inventory c)))
    [
      []; catalog @ catalog; List.map (setj "family" (`String "wrong")) catalog;
    ];
  reject (fun () ->
      ignore
        (build
           (map_first (rows (map_first (setj "iterations" (`Int 11)))) samples)));
  List.iter
    (fun (key, value) ->
      reject (fun () ->
          ignore (build (map_first (rows (map_first (setj key value))) samples))))
    [
      ("ns_per_op", `Float nan);
      ("elapsed_ns", `Float infinity);
      ("elapsed_ns", `Int 0);
      ("allocated_bytes_per_op", `Int (-1));
      ("ns_per_op", `Int 100);
      ("major_collections", `Int (-1));
      ("warmups", `Int 0);
    ];
  reject (fun () ->
      ignore (aggregate [ List.hd samples ] catalog "5.5.0" false));
  reject (fun () ->
      ignore (build (map_first (setj "compiler" (`String "5.2.0")) samples)));
  let changed =
    build
      (List.map
         (rows
            (List.map (fun row ->
                 row
                 |> setj "ns_per_op" (`Float (getn "ns_per_op" row *. 2.))
                 |> setj "elapsed_ns" (`Float (getn "elapsed_ns" row *. 2.))
                 |> setj "allocated_bytes_per_op" (`Int 8))))
         samples)
    |> setj "source_sha256" (`String "changed")
  in
  let delta = List.hd (compare_reports changed report) in
  require
    (getn "time_change_percent" delta = 100.
    && getn "allocation_change_bytes_per_op" delta = 8.
    && field "allocation_change_percent" delta = `Null)
    "Baseline delta";
  List.iter
    (fun key ->
      reject (fun () ->
          ignore (compare_reports report (setj key (`String "changed") report))))
    [
      "schema";
      "compiler";
      "profile";
      "workload_sha256";
      "host_fingerprint";
      "config";
    ];
  reject (fun () ->
      validate_report
        (setj "results" (`List [ setj "median_ns_per_op" (`Int 1) row ]) report));
  reject (fun () ->
      validate_report
        (setj "samples"
           (`List (map_first (setj "seed" (`Int 100)) samples))
           report));
  let observation =
    `Assoc
      [
        ("implementation", `String "httpaf");
        ("consumed_bytes", `Int 98);
        ("wire_bytes", `Int 100);
        ("reason", `String "Body EOF before framing");
      ]
  in
  let group =
    `Assoc
      [
        ("family", `String "body");
        ("comparison", `String "request/chunked");
        ("excluded_implementations", strings [ "httpkit"; "httpaf"; "httpun" ]);
        ("observations", `List [ observation ]);
      ]
  in
  validate_exclusions [ group ] [];
  reject (fun () ->
      validate_exclusions [ group ]
        [
          `Assoc
            [
              ("family", `String "body");
              ("comparison", `String "request/chunked");
            ];
        ]);
  reject (fun () -> validate_exclusions [ group; group ] []);
  List.iter
    (fun (k, v) ->
      reject (fun () ->
          validate_exclusions
            [ setj "observations" (`List [ setj k v observation ]) group ]
            []))
    [
      ("implementation", `String "httpkit");
      ("consumed_bytes", `Int 100);
      ("reason", `String "");
    ];
  let catalog =
    List.map
      (fun name ->
        `Assoc
          [
            ("id", `String ("router/external/lookup/" ^ name));
            ("family", `String "router");
            ("comparison", `String "lookup");
            ("implementation", `String name);
            ("iterations", `Int 10);
            ("bytes_per_op", `Int 0);
          ])
      [ "httpkit"; "routes" ]
  in
  let samples =
    List.mapi
      (fun i times -> sample i (List.map2 measurement catalog times))
      [ [ 10.; 20. ]; [ 20.; 20. ]; [ 100.; 300. ] ]
  in
  let results = aggregate samples catalog "5.5.0" false in
  let comparisons = library_comparisons results samples in
  let report =
    `Assoc
      [
        ("schema", `Int 1);
        ("catalog", `List catalog);
        ("samples", `List samples);
        ("results", `List results);
        ("compiler", `String "5.5.0");
        ( "config",
          `Assoc
            [
              ("quick", `Bool false);
              ("samples", `Int 3);
              ("seeds", `List [ `Int 0; `Int 1; `Int 2 ]);
            ] );
        ("library_comparisons", `List comparisons);
      ]
  in
  validate_report report;
  require
    (field "sample_time_ratios" (List.hd comparisons)
     = `List [ `Float 2.; `Float 1.; `Float 3. ]
    && getn "median_other_over_httpkit_time_ratio" (List.hd comparisons) = 2.)
    "Paired ratios";
  require
    (contains (markdown report) "Below 1 means the other library was faster")
    "Report ratio direction";
  List.iter
    (fun key ->
      reject (fun () ->
          validate_report
            (setj "library_comparisons"
               (`List (map_first (setj key (`Int 1000000)) comparisons))
               report)))
    [ "median_other_over_httpkit_time_ratio"; "other_allocated_bytes_per_op" ];
  reject (fun () ->
      validate_report
        (setj "samples"
           (`List
              (map_first (setj "exclusions" (strings [ "unexpected" ])) samples))
           report));
  reject (fun () ->
      validate_report (setj "library_comparisons" (`List []) report));
  reject (fun () -> ignore (library_comparisons [ List.hd results ] samples));
  reject (fun () ->
      ignore
        (library_comparisons
           (map_first (setj "bytes_per_op" (`Int 10)) results)
           samples));
  reject (fun () ->
      ignore
        (aggregate
           (map_first
              (rows (map_first (setj "implementation" (`String "routes"))))
              samples)
           catalog "5.5.0" false));
  print_endline
    "PASS benchmark aggregation, calibration, paired comparisons and \
     retained-evidence controls"

let selection () =
  Build.call [ "build"; "bench/suite_bench.exe" ];
  let catalog ?(success = true) args =
    let r =
      Process.run ~check:false ~timeout:60.
        (Build.binary "bench/suite_bench.exe" :: "--external" :: args)
    in
    require (Process.status_code r.status = 0 = success) r.stderr;
    if success then Yojson.Basic.from_string r.stdout else `String r.stderr
  in
  List.iter
    (fun args ->
      let listed = catalog (args @ [ "--list" ])
      and prepared = catalog (args @ [ "--preflight-only" ]) in
      require
        (equal listed prepared
        && List.length (list (field "results" listed)) = 3)
        "Selection/preflight inventory changed")
    [
      [ "--family"; "exchange"; "--case"; "writer/fixed/bytes-0/messages-8" ];
      [
        "--family";
        "body";
        "--case";
        "request/fixed/bytes-4096/step-16384/immediate/owned-scan";
      ];
    ];
  require
    (contains
       (string
          (catalog ~success:false
             [ "--family"; "exchange"; "--case"; "/httpkit"; "--list" ]))
       "complete comparison groups")
    "Partial group was not rejected";
  print_endline
    "PASS benchmark listing, selected preflight and incomplete-group rejection"
