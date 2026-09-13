open Common

let core =
  [
    ( "framing-cl-te",
      "lib/http1/httpkit_http1.ml",
      "if cl <> [] && te <> [] then Error Ambiguous_framing",
      "if false && cl <> [] && te <> [] then Error Ambiguous_framing",
      "test/http1/http1_test.exe" );
    ( "foreign-request-id",
      "lib/engine/httpkit_engine.ml",
      "a.owner == b.owner && a.number = b.number",
      "a.owner == a.owner && a.number = b.number",
      "test/engine/engine_test.exe" );
    ( "output-accounting",
      "lib/engine/httpkit_engine.ml",
      "t.queued <- t.queued - count;",
      "t.queued <- t.queued - min count 0;",
      "test/engine/engine_test.exe" );
  ]

let framework =
  [
    ( "cookie-secure-default",
      "lib/web/cookie.ml",
      "?(secure = true)",
      "?(secure = false)",
      "test/web/web_test.exe" );
    ( "multipart-quota",
      "lib/web/multipart.ml",
      "if n > t.max_part - t.part_bytes then",
      "if false && n > t.max_part - t.part_bytes then",
      "test/web/web_test.exe" );
    ( "session-expiry",
      "lib/web/session.ml",
      "s.expires <= now",
      "false && s.expires <= now",
      "test/web/web_test.exe" );
    ( "request-lifetime",
      "lib/web_eio/app.ml",
      "if not !alive then",
      "if false && not !alive then",
      "test/web_eio/runtime_test.exe" );
  ]

let dependency_env names =
  let compiler = Build.compiler () in
  let selected =
    Build.output
      ([ "exec"; "--"; "ocamlfind"; "query"; "-recursive"; "-format"; "%d" ]
      @ names)
    |> lines
  in
  let rec lib p =
    if
      Filename.basename p = "lib"
      && Filename.basename (Filename.dirname p) = "target"
    then p
    else
      let parent = Filename.dirname p in
      if parent = p then fail "No locked dependency root for %s" p
      else lib parent
  in
  let paths = List.map lib selected |> List.sort_uniq String.compare in
  let env = clean_ocaml (Build.environment ()) in
  set
    (set env "PATH" (Filename.dirname compiler ^ ":" ^ getenv env "PATH" ""))
    "OCAMLPATH" (String.concat ":" paths)

let main layer =
  require
    (List.mem layer [ "core"; "framework" ])
    "Mutation layer must be core or framework";
  let digest = Build.source_hash () in
  let env =
    dependency_env
      [
        "alcotest";
        "qcheck-core";
        "yojson";
        "base64";
        "mtime.clock.os";
        "eio_main";
        "lwt.unix";
        "crowbar";
        "ipaddr";
        "digestif";
        "eqaf";
      ]
  in
  let entries = if layer = "framework" then framework else core in
  let directory =
    temp_dir
      ~parent:
        (root / "_artifacts"
        / if layer = "framework" then "framework" else "mutations")
      "mutations-"
  in
  let results =
    with_temp "httpkit-mutants-" (fun stage ->
        List.iter
          (fun p -> copy (root / p) (stage / p))
          [ "lib"; "test"; "fuzz"; "examples"; "bench" ];
        Array.iter
          (fun p -> if ends ~suffix:".opam" p then copy (root / p) (stage / p))
          (Sys.readdir root);
        Consumers.project stage;
        let build target =
          ignore (Process.run ~cwd:stage ~env [ Build.dune; "build"; target ])
        in
        let execute target =
          Process.run ~cwd:stage ~env ~check:false ~timeout:60.
            [ stage / "_build/default" / target ]
        in
        List.map (fun (_, _, _, _, target) -> target) entries
        |> List.sort_uniq String.compare
        |> List.iter (fun target ->
            build target;
            let r = execute target in
            require
              (Process.status_code r.status = 0)
              ("Baseline failed: " ^ r.stdout ^ r.stderr));
        List.map
          (fun (name, file, before, after, target) ->
            let p = stage / file in
            let original = read p in
            let re = Str.regexp_string before in
            let count =
              List.length
                (Str.full_split re original
                |> List.filter (function Str.Delim _ -> true | _ -> false))
            in
            require (count = 1) ("Mutation site drift: " ^ name);
            Fun.protect
              ~finally:(fun () -> write p original)
              (fun () ->
                write p (Str.global_replace re after original);
                build target;
                let r = execute target in
                write (directory / (name ^ ".log")) (r.stdout ^ r.stderr);
                require
                  (Process.status_code r.status > 0
                  && contains (r.stdout ^ r.stderr)
                       (if layer = "framework" then "Fatal error" else "FAIL"))
                  ("Mutant survived or infrastructure failed: " ^ name);
                `Assoc
                  [
                    ("name", `String name);
                    ("status", `String "KILLED");
                    ("compiled", `Bool true);
                    ("suite", `String target);
                  ]))
          entries)
  in
  require (Build.source_hash () = digest) "Sources changed during mutations";
  let fields =
    [
      ("status", `String "PASS");
      ("compiler", `String Build.version);
      ("results", `List results);
      ( "scope",
        `String "Curated compiled mutants; not an exhaustive mutation score" );
    ]
  in
  Build.record
    (if layer = "framework" then "framework/mutations.json"
     else "mutations-5.5.0.json")
    fields;
  save
    (directory / "report.json")
    (`Assoc (("source_sha256", `String digest) :: fields));
  Printf.printf "PASS %d compiled %s mutants killed\n%!" (List.length results)
    layer
