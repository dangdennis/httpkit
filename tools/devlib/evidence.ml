open Common

let check milestone =
  require
    (List.mem milestone [ "M0"; "M2"; "M3"; "M4"; "M5"; "M6" ])
    "Unknown evidence milestone";
  let expected = Build.source_hash () in
  let rank =
    try int_of_string (String.sub milestone 1 (String.length milestone - 1))
    with _ -> fail "Invalid milestone"
  in
  let names =
    [ "compiler-5.5.0.json"; "afl/evidence.json" ]
    @
    if rank >= 6 then [ "interop-5.5.0.json"; "performance-5.5.0.json" ] else []
  in
  let results =
    List.map
      (fun name ->
        let status =
          try
            let data = json (root / "_artifacts" / name) in
            let ok =
              field "source_sha256" data = `String expected
              && field "status" data = `String "PASS"
            in
            let ok =
              if starts ~prefix:"compiler-" name then
                let benchmark =
                  if rank >= 2 then
                    json
                      (root / "_artifacts"
                      / ("core-bench-"
                        ^ string (field "compiler" data)
                        ^ ".json"))
                  else `Null
                in
                ok
                && (rank < 2
                   || field "core_consumer" data = `Bool true
                      && field "odoc" data = `String "3.2.1"
                      && field "source_sha256" benchmark = `String expected)
                && (rank < 3 || field "http1_consumer" data = `Bool true)
                && (rank < 4 || field "engine_consumer" data = `Bool true)
                && (rank < 5 || field "adapter_consumer" data = `Bool true)
              else if name = "afl/evidence.json" then
                ok
                && List.for_all
                     (fun (minimum, key) ->
                       rank < minimum
                       ||
                       match field key data with
                       | `Int n -> n >= 10
                       | _ -> false)
                     [
                       (2, "core_execs"); (3, "http1_execs"); (4, "engine_execs");
                     ]
              else if starts ~prefix:"interop-" name then
                ok
                && Release.inventory (field "results" data) "lane" Release.lanes
              else if starts ~prefix:"performance-" name then
                ok
                && field "hard_queue_bound" data = `Int 32768
                && List.length (list (field "mixed_loads" data)) = 2
              else ok
            in
            if ok then "PASS" else "STALE_OR_FAILED"
          with Sys_error _ | Yojson.Json_error _ | Error _ ->
            "MISSING_OR_INVALID"
        in
        (name, `String status))
      names
  in
  let ok = List.for_all (fun (_, v) -> v = `String "PASS") results in
  let report =
    `Assoc
      [
        ("milestone", `String milestone);
        ("status", `String (if ok then "PASS" else "INFRA_ERROR"));
        ("source_sha256", `String expected);
        ("evidence", `Assoc results);
      ]
  in
  print_endline (Yojson.Basic.pretty_to_string report);
  if not ok then exit 2
