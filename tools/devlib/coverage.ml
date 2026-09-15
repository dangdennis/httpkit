open Common

let summary_row line =
  try
    Scanf.sscanf (String.trim line) "%f %% %d/%d %s%!"
      (fun percent visited total file ->
        if
          total > 0 && visited >= 0 && visited <= total
          && Float.is_finite percent && percent >= 0. && percent <= 100.
          && starts ~prefix:"lib/" file
        then Some (file, visited, total)
        else None)
  with _ -> None

let main layer =
  require
    (List.mem layer [ "core"; "framework"; "extensions" ])
    "Coverage layer must be core, framework or extensions";
  let digest = Build.source_hash () in
  let directory =
    temp_dir
      ~parent:
        (root / "_artifacts"
        / if layer = "core" then "coverage" else "framework")
      (layer ^ "-coverage-")
  in
  let env = set (Build.environment ()) "BISECT_FILE" (directory / "point") in
  let run args =
    let r = Process.run ~env (Build.command ~coverage:true args) in
    r.stdout ^ r.stderr
  in
  let suites, layers, excluded_modules =
    match layer with
    | "core" ->
        ( [
            "test/core";
            "test/http1";
            "test/engine";
            "test/adapter";
            "test/middleware";
            "test/router";
          ],
          [ "core"; "http1"; "engine" ],
          [ "lib/core/httpkit_core.ml" ] )
    | "framework" ->
        ( [ "test/web"; "test/web_eio"; "test/db_eio"; "test/production" ],
          [ "web"; "web_eio"; "db_eio" ],
          [
            "lib/web/httpkit.ml";
            "lib/web/observation.ml";
            "lib/web_eio/httpkit_eio.ml";
          ] )
    | _ ->
        ( [ "test/extensions"; "test/production"; "examples/passwords" ],
          [ "cookie"; "password"; "session_eio"; "oidc"; "oidc_eio"; "web_lwt" ],
          [ "lib/web_lwt/httpkit_lwt.ml" ] )
  in
  write (directory / "tests.log")
    (run ([ "runtest"; "--instrument-with"; "bisect_ppx"; "--force" ] @ suites));
  if layer = "core" then
    List.iter
      (fun name ->
        write
          (directory / (name ^ ".log"))
          (run
             [
               "exec";
               "--instrument-with";
               "bisect_ppx";
               "./fuzz/" ^ name ^ ".exe";
               "--";
               "-r";
               "10000";
               "-s";
               "42";
             ]))
      [ "http1_fuzz"; "engine_fuzz"; "release_fuzz"; "adapter_fuzz" ];
  if layer = "framework" then (
    ignore
      (run
         [
           "build";
           "--instrument-with";
           "bisect_ppx";
           "examples/framework/server.exe";
         ]);
    List.iter
      (fun (name, args) ->
        let r =
          Process.run ~env [ Sys.executable_name; name; "--binary"; args ]
        in
        write (directory / (name ^ ".log")) (r.stdout ^ r.stderr))
      [
        ( "framework-test",
          "_build-coverage/default/examples/framework/server.exe" );
        ("databases", "_build-coverage/default/test/db_eio/db_test.exe");
      ]);
  let summary =
    run
      [
        "exec";
        "--";
        "bisect-ppx-report";
        "summary";
        "--coverage-path=" ^ directory;
        "--per-file";
      ]
  in
  write (directory / "summary.txt") summary;
  ignore
    (run
       [
         "exec";
         "--";
         "bisect-ppx-report";
         "html";
         "--coverage-path=" ^ directory;
         "-o";
         directory / "html";
       ]);
  ignore
    (run
       [
         "exec";
         "--";
         "bisect-ppx-report";
         "coveralls";
         "--coverage-path=" ^ directory;
         directory / "lines.json";
       ]);
  let rows = lines summary |> List.filter_map summary_row in
  let required =
    List.concat_map
      (fun l ->
        Array.to_list (Sys.readdir (root / "lib" / l))
        |> List.filter (ends ~suffix:".ml")
        |> List.map (fun p -> "lib/" ^ l ^ "/" ^ p))
      layers
    |> List.filter (fun p -> not (List.mem p excluded_modules))
  in
  let selected = List.filter (fun (p, _, _) -> List.mem p required) rows in
  let missing =
    List.filter
      (fun p -> not (List.exists (fun (f, _, _) -> p = f) selected))
      required
  in
  let visited = List.fold_left (fun n (_, v, _) -> n + v) 0 selected
  and total = List.fold_left (fun n (_, _, t) -> n + t) 0 selected in
  require
    (total > 0 && missing = [] && Build.source_hash () = digest)
    "Empty, incomplete or stale coverage";
  let rows_json rows =
    `List
      (List.map
         (fun (p, v, t) ->
           `Assoc
             [
               ("file", `String p);
               ("visited", `Int v);
               ("covered", `Int v);
               ("total", `Int t);
             ])
         rows)
  in
  let fields =
    [
      ("status", `String (if layer = "framework" then "MEASURED" else "PASS"));
      ("compiler", `String Build.version);
      ("source_sha256", `String digest);
      ("metric", `String "instrumented points, not branches");
      ("visited", `Int visited);
      ("covered", `Int visited);
      ("total", `Int total);
      ("percent", `Float (100. *. float visited /. float total));
      ("files", rows_json (if layer = "core" then rows else selected));
      ("missing_files", strings missing);
      ("missing", strings missing);
      ("directory", `String directory);
      ("report_directory", `String directory);
      ( "exclusions",
        strings
          (excluded_modules
          @ [
              "Build configuration";
              "Native linkage shim";
              "Upstream dependencies";
            ]) );
    ]
  in
  let name =
    if layer = "core" then "coverage.json"
    else if layer = "framework" then "framework/coverage.json"
    else "framework/extensions-coverage.json"
  in
  save (root / "_artifacts" / name) (`Assoc fields);
  save (directory / "report.json") (`Assoc fields);
  Printf.printf "PASS %s coverage: %d/%d points (%.2f%%)\n%!" layer visited
    total
    (100. *. float visited /. float total)
