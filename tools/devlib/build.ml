open Common

let version = "5.5.0"
let manifest () = json (root / "toolchain/manifest.json")
let dune = root / ".toolchain/bin/dune"

let environment () =
  let env = environment () in
  let selected = getenv env "HARNESS_COMPILER" version in
  require (selected = version) "HARNESS_COMPILER must be 5.5.0";
  let env =
    List.filter
      (fun (k, _) ->
        not
          (List.mem k
             [
               "DUNE_WORKSPACE";
               "DUNE_BUILD_DIR";
               "OCAMLPATH";
               "OCAMLLIB";
               "CAML_LD_LIBRARY_PATH";
               "DUNE_CONFIG__PKG";
               "DUNE_CONFIG__PORTABLE_LOCK_DIR";
               "DUNE_CONFIG__RELOCATABLE_COMPILER";
             ]))
      env
  in
  let path =
    String.split_on_char ':' (getenv env "PATH" "")
    |> List.filter (( <> ) (root / ".toolchain/bin"))
  in
  env |> fun e ->
  set e "PATH" (String.concat ":" ((root / ".toolchain/bin") :: path))
  |> fun e ->
  set e "HARNESS_COMPILER" version |> fun e ->
  set e "XDG_CACHE_HOME" (root / ".toolchain/cache")

let command ?(coverage = false) args =
  let args =
    if args = [ "pkg"; "lock" ] then args @ [ "dune.lock" ] else args
  in
  let build = if coverage then "_build-coverage" else "_build-pkg-" ^ version in
  let flags =
    [
      ("--workspace="
      ^ (root / if coverage then "dune-workspace.coverage" else "dune-workspace")
      );
    ]
  in
  let flags =
    if
      List.exists
        (fun s -> s = "--build-dir" || starts ~prefix:"--build-dir=" s)
        args
    then flags
    else flags @ [ "--build-dir=" ^ build ]
  in
  match args with
  | "pkg" :: sub :: rest -> (dune :: "pkg" :: sub :: flags) @ rest
  | sub :: rest -> (dune :: sub :: flags) @ rest
  | [] -> [ dune ]

let run ?coverage ?(check = true) args =
  Process.run ~env:(environment ()) ~check (command ?coverage args)

let output args = (run args).stdout

let call args =
  let r = run args in
  print_string r.stdout;
  prerr_string r.stderr

let binary p = root / ("_build-pkg-" ^ version ^ "/default/" ^ p)

let compiler () =
  Unix.realpath
    (String.trim (output [ "exec"; "--"; "sh"; "-c"; "command -v ocamlc" ]))

let source_hash () =
  let paths =
    List.map
      (fun p -> root / p)
      [
        "mise.toml";
        "httpkit-core.opam";
        "dune";
        "dune-project";
        "httpkit-harness.opam";
        "dune-workspace";
        "dune-workspace.coverage";
        "README.md";
        "SECURITY.md";
        "LICENSE";
      ]
  in
  let paths =
    paths
    @ (Array.to_list (Sys.readdir root)
      |> List.filter (ends ~suffix:".opam")
      |> List.map (fun p -> root / p))
  in
  let paths =
    paths
    @ List.concat_map
        (fun p -> files (root / p))
        [
          "docs";
          "examples";
          "lib";
          "bench";
          "test";
          "fuzz";
          "tools";
          "toolchain";
          ".github";
          "dune.lock";
          "coverage.lock";
        ]
  in
  let ctx =
    List.sort String.compare paths
    |> List.fold_left
         (fun ctx p ->
           if not (Sys.file_exists p) then ctx
           else
             let relative =
               String.sub p
                 (String.length root + 1)
                 (String.length p - String.length root - 1)
             in
             Digestif.SHA256.feed_string ctx
               (relative ^ "\000" ^ read p ^ "\000"))
         Digestif.SHA256.empty
  in
  Digestif.SHA256.(to_hex (get ctx))

let record name fields =
  save
    (root / "_artifacts" / name)
    (`Assoc
       (("source_sha256", `String (source_hash ()))
       :: ("platform", `String (String.trim (Process.output [ "uname"; "-sm" ])))
       :: fields))

let locked_packages () =
  files (root / "dune.lock")
  |> List.filter (ends ~suffix:".pkg")
  |> List.map (fun p ->
      let re = Str.regexp "(version \\([^)]+\\))" in
      ignore (Str.search_forward re (read p) 0);
      (Filename.basename p, `String (Str.matched_group 1 (read p))))
  |> fun xs -> `Assoc xs
