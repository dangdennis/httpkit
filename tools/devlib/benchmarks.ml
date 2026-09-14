open Common

let families =
  [
    "all";
    "core";
    "router";
    "http1";
    "middleware";
    "engine";
    "body";
    "exchange";
    "router-experiment";
  ]

let implementations = function
  | "router" -> [ "httpkit"; "routes" ]
  | "http1" | "body" | "exchange" -> [ "httpkit"; "httpaf"; "httpun" ]
  | "router-experiment" -> [ "httpkit"; "prefix-index"; "deep-index" ]
  | _ -> []

let finite ?(positive = false) = function
  | `Int n -> if positive then n > 0 else n >= 0
  | `Float f -> Float.is_finite f && if positive then f > 0. else f >= 0.
  | _ -> false

let getn key row = number (field key row)
let gets key row = string (field key row)
let geti key row = int (field key row)

let setj key value row =
  `Assoc ((key, value) :: List.remove_assoc key (assoc row))

let canonical j =
  let rec go = function
    | `Assoc xs ->
        `Assoc (List.sort compare (List.map (fun (k, v) -> (k, go v)) xs))
    | `List xs -> `List (List.map go xs)
    | x -> x
  in
  go j

let equal a b = canonical a = canonical b
let default key value row = match field key row with `Null -> value | x -> x

let median values =
  let a = Array.of_list values in
  Array.sort Float.compare a;
  let n = Array.length a in
  require (n > 0) "Empty statistics";
  if n mod 2 = 1 then a.(Stdlib.(n / 2))
  else (a.(Stdlib.(n / 2) - 1) +. a.(Stdlib.(n / 2))) /. 2.

let mean values = List.fold_left ( +. ) 0. values /. float (List.length values)

let stdev values =
  let avg = mean values in
  sqrt
    (List.fold_left (fun s x -> s +. ((x -. avg) ** 2.)) 0. values
    /. float (List.length values - 1))

let median_interval values =
  let rng = Random.State.make [| 7331 |] and a = Array.of_list values in
  let medians =
    Array.init 2000 (fun _ ->
        median
          (List.init (Array.length a) (fun _ ->
               a.(Random.State.int rng (Array.length a)))))
  in
  Array.sort Float.compare medians;
  `List [ `Float medians.(49); `Float medians.(1949) ]

let inventory rows =
  require (rows <> []) "Empty workload catalog";
  let result =
    List.map
      (fun row ->
        let id = gets "id" row and family = gets "family" row in
        require
          (List.mem family (List.tl families)
          && starts ~prefix:(family ^ "/") id)
          "Invalid family";
        let iterations = geti "iterations" row
        and bytes = geti "bytes_per_op" row in
        require (iterations > 0 && bytes >= 0) "Invalid workload size";
        let iterations =
          match field "base_iterations" row with
          | `Null -> iterations
          | `Int n ->
              require
                (n > 0 && n <= iterations && iterations <= 10000000)
                "Invalid calibrated iterations";
              n
          | _ -> fail "Invalid calibrated iterations"
        in
        let fields =
          [
            ("id", `String id);
            ("family", `String family);
            ("iterations", `Int iterations);
            ("bytes_per_op", `Int bytes);
          ]
        in
        let fields =
          if
            field "comparison" row <> `Null
            || field "implementation" row <> `Null
          then (
            let impl = gets "implementation" row
            and comparison = gets "comparison" row in
            require
              (List.mem impl (implementations family) && comparison <> "")
              "Invalid comparison labels";
            require
              (id = family ^ "/external/" ^ comparison ^ "/" ^ impl)
              "Comparison id differs";
            fields
            @ [
                ("comparison", `String comparison);
                ("implementation", `String impl);
              ])
          else fields
        in
        (id, `Assoc fields))
      rows
  in
  require
    (List.length (List.sort_uniq String.compare (List.map fst result))
    = List.length rows)
    "Duplicate case id";
  List.sort compare result

let validate_exclusions exclusions catalog =
  let seen = ref [] in
  List.iter
    (fun group ->
      let family = gets "family" group
      and comparison = gets "comparison" group in
      require
        (family = "body" && comparison <> ""
        && (not (List.mem comparison !seen))
        && not
             (List.exists
                (fun row ->
                  field "family" row = `String family
                  && field "comparison" row = `String comparison)
                catalog))
        "Invalid or timed exclusion";
      seen := comparison :: !seen;
      require
        (List.sort compare (list (field "excluded_implementations" group))
        = List.sort compare (list (strings [ "httpaf"; "httpkit"; "httpun" ])))
        "Partial comparison exclusion";
      let observations = list (field "observations" group) and impls = ref [] in
      require (observations <> []) "Missing exclusion observations";
      List.iter
        (fun row ->
          let impl = gets "implementation" row in
          require
            (List.mem impl [ "httpaf"; "httpun" ] && not (List.mem impl !impls))
            "Invalid excluded observer";
          impls := impl :: !impls;
          require
            (geti "consumed_bytes" row >= 0
            && geti "consumed_bytes" row < geti "wire_bytes" row)
            "Invalid exclusion byte counts";
          require (gets "reason" row <> "") "Missing exclusion reason")
        observations)
    exclusions

let aggregate samples catalog compiler quick =
  let expected = inventory catalog in
  require (List.length samples >= 2) "At least two process samples required";
  List.iter
    (fun sample ->
      let min_ms = default "min_ms" (`Int 0) sample in
      require
        (finite min_ms && number min_ms <= 1000.)
        "Invalid calibration duration";
      require
        ((not quick) || number min_ms = 0.)
        "Quick samples cannot be calibrated";
      require
        (field "schema" sample = `Int 1
        && field "compiler" sample = `String compiler
        && field "quick" sample = `Bool quick)
        "Incompatible sample metadata";
      let rows = list (field "results" sample) in
      require (inventory rows = expected) "Sample workload catalog differs";
      List.iter
        (fun row ->
          require
            (finite ~positive:true (field "elapsed_ns" row)
            && finite ~positive:true (field "ns_per_op" row)
            && finite (field "allocated_bytes_per_op" row))
            "Invalid measurement";
          let elapsed = getn "elapsed_ns" row
          and computed =
            getn "ns_per_op" row *. float (geti "iterations" row)
          in
          require
            (abs_float (elapsed -. computed)
            <= 1e-9 *. max (abs_float elapsed) (abs_float computed))
            "Inconsistent elapsed time";
          require
            (geti "warmups" row
            = min 3
                (int (default "base_iterations" (field "iterations" row) row)))
            "Invalid warmup count";
          List.iter
            (fun key -> require (geti key row >= 0) "Invalid GC count")
            [ "minor_collections"; "major_collections" ])
        rows)
    samples;
  List.map
    (fun (id, entry) ->
      let rows =
        List.map
          (fun sample ->
            List.find
              (fun row -> field "id" row = `String id)
              (list (field "results" sample)))
          samples
      in
      let times = List.map (getn "ns_per_op") rows in
      let med = median times and cv = stdev times /. mean times in
      let met =
        List.for_all2
          (fun row sample ->
            getn "elapsed_ns" row
            >= number (default "min_ms" (`Int 0) sample) *. 1e6)
          rows samples
      in
      `Assoc
        (assoc entry
        @ [
            ("median_ns_per_op", `Float med);
            ("median_bootstrap_95_ns", median_interval times);
            ( "timing_quality",
              `String
                (if not met then "short-batch"
                 else if cv > 0.1 then "noisy"
                 else "low-observed-variation") );
            ("min_ns_per_op", `Float (List.fold_left min infinity times));
            ("max_ns_per_op", `Float (List.fold_left max neg_infinity times));
            ("coefficient_of_variation", `Float cv);
            ( "median_allocated_bytes_per_op",
              `Float (median (List.map (getn "allocated_bytes_per_op") rows)) );
            ("operations_per_second", `Float (1e9 /. med));
            ( "payload_mib_per_second",
              if geti "bytes_per_op" entry = 0 then `Null
              else
                `Float
                  (float (geti "bytes_per_op" entry) *. 1e9 /. med /. 1048576.)
            );
          ]))
    expected

let groups results =
  let keys =
    results
    |> List.filter (fun row -> field "comparison" row <> `Null)
    |> List.map (fun row -> (gets "family" row, gets "comparison" row))
    |> List.sort_uniq compare
  in
  List.map
    (fun (family, comparison) ->
      let rows =
        List.filter
          (fun row ->
            field "family" row = `String family
            && field "comparison" row = `String comparison)
          results
      in
      require
        (List.sort String.compare (List.map (gets "implementation") rows)
        = List.sort String.compare (implementations family))
        "Incomplete library comparison";
      (family, comparison, rows))
    keys

let library_comparisons results samples =
  groups results
  |> List.concat_map (fun (family, workload, rows) ->
      let ours =
        List.find
          (fun row -> field "implementation" row = `String "httpkit")
          rows
      in
      List.sort
        (fun a b ->
          compare (field "implementation" a) (field "implementation" b))
        rows
      |> List.filter_map (fun other ->
          require
            (field "iterations" ours = field "iterations" other
            && field "bytes_per_op" ours = field "bytes_per_op" other)
            "Comparison sizes differ";
          if field "implementation" other = `String "httpkit" then None
          else
            let ratios =
              List.map
                (fun sample ->
                  let rows = list (field "results" sample) in
                  let find id =
                    List.find (fun row -> field "id" row = id) rows
                  in
                  getn "ns_per_op" (find (field "id" other))
                  /. getn "ns_per_op" (find (field "id" ours)))
                samples
            in
            Some
              (`Assoc
                 [
                   ("family", `String family);
                   ("workload", `String workload);
                   ("implementation", field "implementation" other);
                   ("httpkit_ns_per_op", field "median_ns_per_op" ours);
                   ("other_ns_per_op", field "median_ns_per_op" other);
                   ( "median_other_over_httpkit_time_ratio",
                     `Float (median ratios) );
                   ( "sample_time_ratios",
                     `List (List.map (fun f -> `Float f) ratios) );
                   ( "httpkit_allocated_bytes_per_op",
                     field "median_allocated_bytes_per_op" ours );
                   ( "other_allocated_bytes_per_op",
                     field "median_allocated_bytes_per_op" other );
                 ])))

let validate_report report =
  require (field "schema" report = `Int 1) "Unsupported report schema";
  let catalog = list (field "catalog" report)
  and samples = list (field "samples" report)
  and config = field "config" report in
  let exclusions = list (field "exclusions" report) in
  validate_exclusions exclusions catalog;
  let results =
    aggregate samples catalog (gets "compiler" report)
      (field "quick" config = `Bool true)
  in
  require
    (equal (field "results" report) (`List results))
    "Report summary does not match retained samples";
  require
    (List.length samples = geti "samples" config)
    "Report sample count differs";
  require
    (List.for_all
       (fun s ->
         number (default "min_ms" (`Int 0) s)
         = number (default "min_ms" (`Int 0) config))
       samples)
    "Report calibration differs";
  require
    (`List (List.map (field "seed") samples) = field "seeds" config)
    "Report seed order differs";
  require
    (List.for_all (fun s -> list (field "exclusions" s) = exclusions) samples)
    "Report exclusions differ";
  require
    (equal
       (`List (list (field "library_comparisons" report)))
       (`List (library_comparisons results samples)))
    "Library comparisons differ from retained samples"

let compare_reports current baseline =
  List.iter
    (fun key ->
      require
        (equal (field key current) (field key baseline))
        ("Incompatible baseline: " ^ key))
    [
      "schema";
      "compiler";
      "profile";
      "workload_sha256";
      "host_fingerprint";
      "config";
    ];
  validate_report current;
  validate_report baseline;
  require
    (equal (field "exclusions" current) (field "exclusions" baseline))
    "Baseline exclusions differ";
  require
    (inventory (list (field "catalog" current))
    = inventory (list (field "catalog" baseline)))
    "Baseline catalog differs";
  List.map
    (fun row ->
      let previous =
        List.find
          (fun p -> field "id" row = field "id" p)
          (list (field "results" baseline))
      in
      let before = getn "median_allocated_bytes_per_op" previous in
      let delta = getn "median_allocated_bytes_per_op" row -. before in
      `Assoc
        [
          ("id", field "id" row);
          ( "time_change_percent",
            `Float
              (100.
              *. (getn "median_ns_per_op" row
                  /. getn "median_ns_per_op" previous
                 -. 1.)) );
          ("allocation_change_bytes_per_op", `Float delta);
          ( "allocation_change_percent",
            if before = 0. then `Null else `Float (100. *. delta /. before) );
        ])
    (list (field "results" current))

let workload_hash () =
  let paths =
    (files (root / "bench")
    |> List.filter (fun p ->
        ends ~suffix:".ml" p || Filename.basename p = "dune"))
    @ files (root / "tools/devlib")
    @ files (root / "dune.lock")
    @ List.map
        (fun p -> root / p)
        [
          "tools/dev.ml";
          "tools/dune-pkg";
          "dune";
          "dune-project";
          "dune-workspace";
          "toolchain/manifest.json";
        ]
  in
  let data =
    List.sort String.compare paths
    |> List.map (fun p ->
        String.sub p
          (String.length root + 1)
          (String.length p - String.length root - 1)
        ^ "\000" ^ read p ^ "\000")
    |> String.concat ""
  in
  sha data

let sample_timeout count min_ms =
  require
    (count > 0 && Float.is_finite min_ms && min_ms >= 0. && min_ms <= 1000.)
    "Invalid sample budget";
  let seconds =
    ceil (60. +. (float count *. (0.5 +. (32. *. min_ms /. 1000.))))
  in
  require (seconds <= 43200.) "Selection exceeds 12-hour sample budget";
  max 600. seconds

let markdown report =
  validate_report report;
  let b = Buffer.create 4096 in
  let add fmt = Printf.ksprintf (fun s -> Buffer.add_string b (s ^ "\n")) fmt in
  add "# HTTP toolkit benchmarks\n";
  add "%d cases; %d fresh process samples; OCaml %s; release profile.\n"
    (List.length (list (field "results" report)))
    (List.length (list (field "samples" report)))
    (gets "compiler" report);
  add
    "Timing verdict: **ADVISORY**. Timed operations include correctness \
     checks. Allocation counts GC heap only. These results do not establish \
     reserved hardware or security.\n";
  add
    "| Case | Median ns/op | Range ns/op | CV | Alloc B/op | MiB/s |\n\
     | --- | ---: | ---: | ---: | ---: | ---: |";
  List.iter
    (fun row ->
      add "| %s | %.1f | %.1f–%.1f | %.1f%% | %.1f | %s |" (gets "id" row)
        (getn "median_ns_per_op" row)
        (getn "min_ns_per_op" row) (getn "max_ns_per_op" row)
        (100. *. getn "coefficient_of_variation" row)
        (getn "median_allocated_bytes_per_op" row)
        (match field "payload_mib_per_second" row with
        | `Null -> "-"
        | x -> Printf.sprintf "%.2f" (number x)))
    (list (field "results" report));
  add
    "\n\
     ## Measurement quality\n\n\
     Intervals are descriptive 95%% bootstrap intervals of process-mean \
     medians, not request latency percentiles. Do not rank noisy (>10%% CV) or \
     short-batch cases.\n\n\
     | Case | Quality | Median interval ns/op |\n\
     | --- | --- | ---: |";
  List.iter
    (fun row ->
      let interval = list (field "median_bootstrap_95_ns" row) in
      add "| %s | %s | %.1f–%.1f |" (gets "id" row)
        (gets "timing_quality" row)
        (number (List.nth interval 0))
        (number (List.nth interval 1)))
    (list (field "results" report));
  if list (field "library_comparisons" report) <> [] then (
    add
      "\n\
       ## Library comparisons\n\n\
       Time ratio = other / httpkit, paired within each process. Below 1 means \
       the other library was faster. Parsing, routing and ownership \
       responsibilities differ; no overall winner is implied.\n\n\
       | Family / workload | Other | httpkit ns/op | Other ns/op | Time ratio \
       | httpkit B/op | Other B/op |\n\
       | --- | --- | ---: | ---: | ---: | ---: | ---: |";
    List.iter
      (fun row ->
        add "| %s/%s | %s | %.1f | %.1f | %.3f | %.1f | %.1f |"
          (gets "family" row) (gets "workload" row)
          (gets "implementation" row)
          (getn "httpkit_ns_per_op" row)
          (getn "other_ns_per_op" row)
          (getn "median_other_over_httpkit_time_ratio" row)
          (getn "httpkit_allocated_bytes_per_op" row)
          (getn "other_allocated_bytes_per_op" row))
      (list (field "library_comparisons" report)));
  List.iter
    (fun group ->
      add "\nExcluded workload: %s (full comparison group)"
        (gets "comparison" group);
      List.iter
        (fun row ->
          add "- %s: %d/%d bytes; %s"
            (gets "implementation" row)
            (geti "consumed_bytes" row)
            (geti "wire_bytes" row) (gets "reason" row))
        (list (field "observations" group)))
    (list (field "exclusions" report));
  if field "comparison" report <> `Null then (
    add
      "\n\
       ## Baseline comparison\n\n\
       Positive changes mean slower execution or more allocation. No \
       regression gate is applied.\n\n\
       | Case | Time change | Allocation change B/op |\n\
       | --- | ---: | ---: |";
    List.iter
      (fun row ->
        add "| %s | %+.1f%% | %+.1f |" (gets "id" row)
          (getn "time_change_percent" row)
          (getn "allocation_change_bytes_per_op" row))
      (list (field "comparison" report)));
  Buffer.contents b

let main args =
  let family = option args "--family" "all"
  and samples = int_of_string (option args "--samples" "5")
  and min_ms = float_of_string (option args "--min-ms" "0")
  and case = option args "--case" ""
  and seed = int_of_string (option args "--seed" "42") in
  let quick = flag args "--quick" and external_ = flag args "--external" in
  require
    (List.mem family families && samples >= 2 && samples <= 50 && seed >= 0
    && seed <= 2147483647 - samples
    && Float.is_finite min_ms && min_ms >= 0. && min_ms <= 1000.)
    "Invalid benchmark options";
  require ((not quick) || min_ms = 0.) "Quick mode cannot calibrate";
  require
    ((external_ && (family = "all" || implementations family <> []))
    || (not external_)
       && not (List.mem family [ "body"; "exchange"; "router-experiment" ]))
    "Unsupported external/family selection";
  let before = Build.environment () in
  let clear = Build.measurement_override in
  let env = List.filter (fun (key, _) -> not (clear key)) before in
  let digest = Build.source_hash () and workload = workload_hash () in
  Process.call ~env
    (Build.command
       [
         "build";
         "--profile=release";
         "--build-dir=_build-bench-5.5.0";
         "bench/suite_bench.exe";
       ]);
  let binary = root / "_build-bench-5.5.0/default/bench/suite_bench.exe" in
  let flags =
    [ "--family"; family; "--min-ms"; string_of_float min_ms; "--case"; case ]
    @ (if quick then [ "--quick" ] else [])
    @ if external_ then [ "--external" ] else []
  in
  let preflight =
    Yojson.Basic.from_string
      (Process.output ~env ~timeout:60.
         ((binary :: flags) @ [ "--preflight-only" ]))
  in
  require (field "compiler" preflight = `String Build.version) "Wrong compiler";
  let catalog = list (field "results" preflight) in
  ignore (inventory catalog);
  if external_ then ignore (groups catalog);
  let exclusions = list (field "exclusions" preflight) in
  validate_exclusions exclusions catalog;
  let timeout = sample_timeout (List.length catalog) min_ms in
  Printf.printf "Selected %d cases; process timeout %.0fs\n%!"
    (List.length catalog) timeout;
  let directory = temp_dir ~parent:(root / "_artifacts/benchmarks") "run-" in
  let seeds = List.init samples (fun i -> seed + i) in
  let load () = String.trim (Process.output [ "uptime" ]) in
  let observations = ref [] in
  let measurements =
    List.mapi
      (fun i seed ->
        let before = load () in
        let raw =
          Process.output ~env ~timeout
            ((binary :: flags) @ [ "--seed"; string_of_int seed ])
        in
        observations :=
          !observations
          @ [
              `Assoc
                [
                  ("seed", `Int seed);
                  ("before", `String before);
                  ("after", `String (load ()));
                ];
            ];
        write (directory / Printf.sprintf "sample-%d.json" (i + 1)) raw;
        let sample = Yojson.Basic.from_string raw in
        require
          (number (default "min_ms" (`Int 0) sample) = min_ms
          && list (field "exclusions" sample) = exclusions)
          "Sample/preflight configuration differs";
        Printf.printf "Sample %d/%d: %d cases\n%!" (i + 1) samples
          (List.length (list (field "results" sample)));
        sample)
      seeds
  in
  require
    (Build.source_hash () = digest && workload_hash () = workload)
    "Sources changed during benchmarks";
  let host =
    `Assoc
      [
        ("system", `String (String.trim (Process.output [ "uname"; "-s" ])));
        ("release", `String (String.trim (Process.output [ "uname"; "-r" ])));
        ("machine", `String (String.trim (Process.output [ "uname"; "-m" ])));
      ]
  in
  let results = aggregate measurements catalog Build.version quick in
  let report =
    `Assoc
      [
        ("schema", `Int 1);
        ("status", `String "PASS");
        ("timing_verdict", `String "ADVISORY");
        ("compiler", `String Build.version);
        ("profile", `String "release");
        ("source_sha256", `String digest);
        ("workload_sha256", `String workload);
        ("host", host);
        ( "host_fingerprint",
          `String
            (sha
               (Process.output [ "hostname" ]
               ^ Yojson.Basic.to_string (canonical host))) );
        ("exclusions", `List exclusions);
        ( "cleared_environment",
          strings
            (List.filter_map
               (fun (k, _) -> if clear k then Some k else None)
               before
            |> List.sort String.compare) );
        ("load_observations", `List !observations);
        ("catalog", `List catalog);
        ("samples", `List measurements);
        ( "config",
          `Assoc
            [
              ("family", `String family);
              ("quick", `Bool quick);
              ("samples", `Int samples);
              ("seeds", `List (List.map (fun n -> `Int n) seeds));
              ("external", `Bool external_);
              ("min_ms", `Float min_ms);
              ("case", `String case);
            ] );
        ("results", `List results);
        ( "limitations",
          strings
            [
              "Timed operations include correctness checks and loop overhead.";
              "Sample means are not request latency percentiles.";
              "Host identity does not establish reserved hardware or stable \
               power/load.";
              "GC allocation excludes external Bigarray storage.";
              "OCaml seeded bootstrap resampling; historical workload \
               fingerprints are incompatible.";
              "These measurements do not approve M7 performance or security \
               gates.";
            ] );
      ]
  in
  let report =
    if external_ then
      let packages = assoc (Build.locked_packages ()) in
      let libraries =
        List.map
          (fun name ->
            let matches =
              List.filter
                (fun (key, _) -> starts ~prefix:(name ^ ".") key)
                packages
            in
            require
              (List.length matches = 1)
              ("Ambiguous locked library: " ^ name);
            (name, snd (List.hd matches)))
          [
            "routes";
            "httpaf";
            "httpun";
            "httpun-types";
            "angstrom";
            "bigstringaf";
            "faraday";
          ]
      in
      setj "libraries" (`Assoc libraries)
        (setj "library_comparisons"
           (`List (library_comparisons results measurements))
           report)
    else report
  in
  validate_report report;
  let baseline = option args "--baseline" "" in
  let report =
    if baseline = "" then report
    else
      setj "baseline"
        (`String (absolute baseline))
        (setj "comparison"
           (`List (compare_reports report (json (absolute baseline))))
           report)
  in
  save (directory / "report.json") report;
  write (directory / "report.md") (markdown report);
  Printf.printf "PASS %d cases; timing ADVISORY\n%s\n%!" (List.length results)
    (directory / "report.md")
