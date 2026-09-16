open Common

let package = function
  | "web" -> "httpkit"
  | "web_eio" -> "httpkit-eio"
  | "web_lwt" -> "httpkit-lwt"
  | "eio" -> "httpkit-transport-eio"
  | "lwt" -> "httpkit-transport-lwt"
  | "db_eio" -> "httpkit-db-eio"
  | "session_eio" -> "httpkit-session-eio"
  | "oidc_eio" -> "httpkit-oidc-eio"
  | "client_eio" -> "httpkit-client-eio"
  | "client_lwt" -> "httpkit-client-lwt"
  | s -> "httpkit-" ^ s

let project dir =
  mkdir dir;
  write (dir / "dune-project") "(lang dune 3.24)\n(name installed-consumer)\n";
  write (dir / "dune-workspace") "(lang dune 3.24)\n(pkg disabled)\n"

let rec package_root p =
  let parent = Filename.dirname p in
  if
    Sys.file_exists (parent / "META")
    || Sys.file_exists (parent / "dune-package")
  then package_root parent
  else p

let stubs dirs =
  List.concat_map files dirs
  |> List.filter (fun p ->
      starts ~prefix:"dll" (Filename.basename p) && ends ~suffix:".so" p)
  |> List.map Filename.dirname
  |> List.sort_uniq String.compare
  |> String.concat ":"

type installed = {
  dir : string;
  prefix : string;
  compiler : string;
  env : (string * string) list;
}

let run t ?(check = true) cwd args =
  Process.run ~cwd ~env:t.env ~timeout:300. ~check args

let dune t ?check cwd args = run t ?check cwd (Build.dune :: args)

let with_install layers dependencies f =
  let compiler = Build.compiler () in
  let compiler_dir = Filename.dirname compiler in
  let env = clean_ocaml (Build.environment ()) in
  let env = set env "PATH" (compiler_dir ^ ":" ^ getenv env "PATH" "") in
  with_temp "httpkit-consumer-" (fun dir ->
      let deps = dir / "deps" in
      mkdir deps;
      let paths =
        if dependencies = [] then []
        else
          Build.output
            ([
               "exec"; "--"; "ocamlfind"; "query"; "-recursive"; "-format"; "%d";
             ]
            @ dependencies)
          |> lines |> List.map package_root
          |> List.sort_uniq String.compare
      in
      let paths =
        List.filter
          (fun p ->
            (not (starts ~prefix:(Filename.dirname compiler_dir ^ "/") p))
            && not
                 (List.exists
                    (fun q -> p <> q && starts ~prefix:(q ^ "/") p)
                    paths))
          paths
      in
      List.iter
        (fun p ->
          copy p (deps / Filename.basename p);
          let stub = Filename.dirname p / "stublibs" in
          if Sys.file_exists stub then copy stub (deps / "stublibs"))
        paths;
      let stdlib = String.trim (Process.output ~env [ compiler; "-where" ]) in
      let conf = dir / "findlib.conf" in
      write conf
        (Printf.sprintf "path=%S\nstdlib=%S\n" (deps ^ ":" ^ stdlib) stdlib);
      let env =
        set
          (set (set env "OCAMLPATH" deps) "OCAMLFIND_CONF" conf)
          "CAML_LD_LIBRARY_PATH" (stubs [ deps ])
      in
      let prefix = dir / "installed" and stage = dir / "source" in
      project stage;
      List.iter
        (fun layer ->
          copy (root / "lib" / layer) (stage / layer);
          let p = package layer ^ ".opam" in
          copy (root / p) (stage / p))
        layers;
      let t = { dir; prefix; compiler; env } in
      ignore (dune t stage [ "build"; "@install" ]);
      ignore
        (dune t stage
           ([ "install"; "--prefix"; prefix ] @ List.map package layers));
      let actual =
        Array.to_list (Sys.readdir (prefix / "lib"))
        |> List.filter (( <> ) "stublibs")
        |> List.sort String.compare
      in
      require
        (actual = List.sort String.compare (List.map package layers))
        "Installed package inventory differs";
      write conf
        (Printf.sprintf "path=%S\nstdlib=%S\n"
           ((prefix / "lib") ^ ":" ^ deps ^ ":" ^ stdlib)
           stdlib);
      let env =
        set
          (set env "OCAMLPATH" ((prefix / "lib") ^ ":" ^ deps))
          "CAML_LD_LIBRARY_PATH"
          (stubs [ deps; prefix / "lib" ])
      in
      f { t with env })

let execute t dir name =
  ignore (dune t dir [ "build"; name ^ ".exe"; name ^ ".bc" ]);
  let native =
    (run t dir [ dir / "_build/default" / (name ^ ".exe") ]).stdout
  in
  let byte =
    (run t dir
       [
         Filename.dirname t.compiler / "ocamlrun";
         dir / "_build/default" / (name ^ ".bc");
       ])
      .stdout
  in
  require (native = byte) ("Native/bytecode output differs: " ^ name);
  native

let stanza ?(modules = "") name libraries =
  Printf.sprintf "(executable (name %s) %s (modes byte exe) (libraries %s))\n"
    name
    (if modules = "" then "" else "(modules " ^ modules ^ ")")
    libraries

let check_failure result diagnostic =
  require
    (Process.status_code result.Process.status <> 0
    && contains result.stderr diagnostic)
    ("Expected compile failure: " ^ diagnostic ^ "\n" ^ result.stderr)

let basic kind =
  let layers = if kind = "core" then [ "core" ] else [ "core"; kind ] in
  with_install layers [] (fun t ->
      let consumer = t.dir / "consumer" in
      project consumer;
      let name, source, expected =
        match kind with
        | "core" -> ("consumer", root / "test/api/consumer.ml", None)
        | "middleware" ->
            ( "styles",
              root / "examples/middleware/styles.ml",
              Some "PASS: basic, contextual and transition middleware\n" )
        | "router" ->
            ( "consumer",
              root / "test/api/router/consumer.ml",
              Some "PASS: installed pure router\n" )
        | _ -> fail "Unknown consumer %s" kind
      in
      copy source (consumer / (name ^ ".ml"));
      write (consumer / "dune")
        (stanza ~modules:name name
           (String.concat " " (List.map package layers)));
      let out = execute t consumer name in
      Option.iter
        (fun s -> require (out = s) "Unexpected consumer output")
        expected;
      if kind = "core" then (
        let doc = read (root / "lib/core/doc/index.mld") in
        let re = Str.regexp "{\\[\\(\\(.\\|\n\\)*?\\)\\]}" in
        (* Locate delimiters directly; Str has no non-greedy repetition. *)
        ignore re;
        let start = Str.search_forward (Str.regexp_string "{[") doc 0 + 2 in
        let finish = Str.search_forward (Str.regexp_string "]}") doc start in
        require
          (not
             (contains
                (String.sub doc (finish + 2) (String.length doc - finish - 2))
                "{["))
          "Documentation example inventory changed";
        write
          (consumer / "documentation.ml")
          (String.sub doc start (finish - start)
          ^ "\n\
             let () = assert (Result.is_ok (request \"/\")); assert \
             (Result.is_error (request \"/ bad\"))\n");
        write (consumer / "dune")
          (stanza ~modules:"documentation" "documentation" "httpkit-core");
        ignore (execute t consumer "documentation"));
      let fixtures =
        match kind with
        | "core" ->
            List.map
              (fun (n, d) -> (root / "test/api" / n, d))
              [
                ("forged_method.ml", "Method.t");
                ("forged_header.ml", "Name.t");
                ("forged_value.ml", "Value.t");
                ("forged_target.ml", "Target.t");
                ("forged_status.ml", "Status.t");
                ("private_helper.ml", "Unbound module");
                ("private_harness.ml", "Unbound module");
              ]
        | "middleware" ->
            files (root / "test/api/middleware")
            |> List.filter (ends ~suffix:".ml")
            |> List.map (fun p -> (p, "expected of type"))
        | _ ->
            [ (root / "test/api/router/forged.ml", "Httpkit_router.pattern") ]
      in
      let includes =
        List.concat_map (fun l -> [ "-I"; t.prefix / "lib" / package l ]) layers
      in
      List.iter
        (fun (fixture, diagnostic) ->
          copy fixture (consumer / Filename.basename fixture);
          let r =
            run t ~check:false consumer
              ((t.compiler :: includes) @ [ "-c"; Filename.basename fixture ])
          in
          check_failure r diagnostic;
          if kind <> "core" then
            require
              (not (contains r.stderr "Unbound module"))
              "Compile failure was missing dependencies")
        fixtures);
  Printf.printf "PASS installed %s consumer and negative API controls\n%!" kind

let protocol () =
  with_install [ "core"; "http1"; "engine" ] [ "ipaddr" ] (fun t ->
      let c = t.dir / "consumer" in
      project c;
      let check source libraries expected =
        copy (root / source) (c / "consumer.ml");
        write (c / "dune") (stanza "consumer" libraries);
        let out = execute t c "consumer" in
        if starts ~prefix:"HTTP/1.1" out then ignore (Network.reference out);
        require (out = expected) "Protocol wire differs from reference"
      in
      check "test/api/http1/consumer.ml" "httpkit-core httpkit-http1"
        "HTTP/1.1 200 \r\n\
         transfer-encoding: chunked\r\n\
         set-cookie: a=1\r\n\
         set-cookie: b=2\r\n\
         \r\n\
         3\r\n\
         abc\r\n\
         0\r\n\
         \r\n";
      check "test/api/engine/consumer.ml" "httpkit-core httpkit-engine"
        "HTTP/1.1 200 \r\ncontent-length: 3\r\n\r\nabc";
      check "examples/pure/in_memory.ml" "httpkit-core httpkit-engine"
        "Hello /stream\n";
      write (c / "dune") (stanza "consumer" "httpkit-core httpkit-http1");
      write (c / "consumer.ml")
        "let forge (m:Httpkit_http1.metadata) = {m with persistent=true}\n";
      check_failure
        (dune t ~check:false c [ "build"; "consumer.exe" ])
        "private";
      print_endline
        "PASS installed protocol consumers, wire fixtures, streaming recipe \
         and private metadata")

let adapters () =
  List.iter
    (fun (adapter, runtime, forbidden) ->
      with_install [ "core"; "http1"; "engine"; adapter ]
        [ runtime; "ipaddr"; "mtime.clock.os" ] (fun t ->
          require
            (not (Sys.file_exists (t.dir / "deps" / forbidden)))
            "Opposite runtime dependency";
          let c = t.dir / "consumer" in
          project c;
          List.iter
            (fun n -> copy (root / "examples/runtime" / n) (c / n))
            [ "transform.ml"; adapter ^ "_example.ml" ];
          let name = adapter ^ "_example" in
          write
            (c / (name ^ ".ml"))
            (read (c / (name ^ ".ml"))
            ^ "\n\
               let configured_server ~clock ~accept ~on_error handler = \
               Httpkit_transport_" ^ adapter
            ^ ".serve_connections ~output_limit:4096 ~informational_limit:2 \
               ~clock ~accept ~on_error handler\n\
               let _ = Httpkit_transport_" ^ adapter
            ^ ".failure_to_string (Engine Httpkit_engine.Invalid_command)\n");
          write (c / "dune")
            (stanza name
               ("httpkit-core httpkit-transport-" ^ adapter ^ " " ^ runtime));
          require (execute t c name = "Hello /\n") "Shared handler output";
          if adapter = "eio" then (
            copy
              (root / "examples/personal/eio_streaming.ml")
              (c / "eio_streaming.ml");
            write (c / "dune")
              (stanza ~modules:"eio_streaming" "eio_streaming"
                 "httpkit-transport-eio eio_main");
            require
              (execute t c "eio_streaming" = "Streamed 1048576 bytes each way\n")
              "Streaming example output");
          write (c / "opposite.ml")
            ("let _ = "
            ^ (if adapter = "eio" then "Lwt.return_unit" else "Eio.Fiber.yield")
            ^ "\n");
          write (c / "dune")
            (stanza ~modules:"opposite" "opposite" (package adapter));
          check_failure
            (dune t ~check:false c [ "build"; "opposite.exe" ])
            "Unbound module"))
    [ ("eio", "eio_main", "lwt"); ("lwt", "lwt.unix", "eio") ];
  print_endline
    "PASS separately installed runtime adapters, streaming and \
     opposite-runtime isolation"

let framework_layers =
  [
    "core";
    "http1";
    "engine";
    "eio";
    "middleware";
    "router";
    "web";
    "web_eio";
    "db_eio";
  ]

let framework_deps =
  [
    "eio_main";
    "ipaddr";
    "yojson";
    "base64";
    "digestif";
    "eqaf";
    "mtime.clock.os";
    "caqti-eio.unix";
    "caqti-driver-postgresql";
    "caqti-driver-sqlite3";
  ]

let framework () =
  with_install
    (List.filter (( <> ) "db_eio") framework_layers)
    [
      "eio";
      "ipaddr";
      "yojson";
      "base64";
      "digestif";
      "eqaf";
      "mtime";
      "cstruct";
    ]
    (fun t ->
      List.iter
        (fun backend ->
          require
            (not (Sys.file_exists (t.dir / "deps" / backend)))
            ("Application library unexpectedly requires " ^ backend))
        [ "eio_main"; "eio_posix"; "eio_linux"; "lwt" ];
      let c = t.dir / "backend-independent" in
      project c;
      write (c / "consumer.ml")
        "let () =\n\
         let handler _ = Httpkit_eio.reply (Httpkit.Reply.text \"ok\") in\n\
         let _application = Httpkit_eio.routes\n\
         [Httpkit_eio.route Httpkit_core.Method.get \"/\" handler] in\n\
         print_endline \"Application composition without backend selection\"\n";
      write (c / "dune") (stanza "consumer" "httpkit-eio");
      require
        (execute t c "consumer"
       = "Application composition without backend selection\n")
        "Backend-independent application composition");
  with_install framework_layers framework_deps (fun t ->
      require
        (not (Sys.file_exists (t.dir / "deps/lwt")))
        "Framework depends on Lwt";
      let c = t.dir / "consumer" in
      project c;
      List.iter
        (fun (source, name, libraries) ->
          copy (root / source) (c / (name ^ ".ml"));
          write (c / "dune") (stanza ~modules:name name libraries);
          ignore (execute t c name))
        [
          ("test/web/web_test.ml", "web_test", "httpkit");
          ( "test/web_eio/runtime_test.ml",
            "runtime_test",
            "httpkit-eio eio_main" );
          ("test/db_eio/db_test.ml", "db_test", "httpkit-db-eio eio_main");
        ];
      List.iter
        (fun (source, diagnostic) ->
          write (c / "forged.ml") (source ^ "\n");
          write (c / "dune") (stanza ~modules:"forged" "forged" "httpkit-eio");
          check_failure
            (dune t ~check:false c [ "build"; "forged.exe" ])
            diagnostic)
        [
          ("let _ : Httpkit.Html.t = \"<script>\"", "Httpkit.Html.t");
          ("let _ = Lwt.return_unit", "Unbound module Lwt");
        ];
      print_endline
        "PASS installed framework native/bytecode, HTML opacity and runtime \
         isolation")

let extensions () =
  let layers =
    framework_layers
    @ [
        "lwt";
        "web_lwt";
        "cookie";
        "session_eio";
        "password";
        "oidc";
        "oidc_eio";
      ]
  in
  with_install layers
    (framework_deps
    @ [
        "lwt.unix";
        "argon2";
        "oidc";
        "jose";
        "mirage-crypto-rng.unix";
        "mirage-crypto-pk";
        "dune-configurator";
      ])
    (fun t ->
      List.iter
        (fun (name, libraries) ->
          let c = t.dir / name in
          project c;
          copy (root / "test/extensions" / (name ^ ".ml")) (c / (name ^ ".ml"));
          write (c / "dune") (stanza name libraries);
          ignore (execute t c name);
          Printf.printf "PASS installed native/bytecode: %s\n%!" name)
        [
          ( "auth_test",
            "httpkit-cookie httpkit-password httpkit-oidc \
             mirage-crypto-rng.unix mirage-crypto-pk" );
          ( "sql_session_test",
            "httpkit-session-eio eio_main caqti-eio mirage-crypto-rng.unix" );
          ("lwt_app_test", "httpkit-lwt lwt.unix mirage-crypto-rng.unix");
          ( "oidc_eio_test",
            "httpkit-oidc-eio eio_main mirage-crypto-rng.unix mirage-crypto-pk"
          );
        ];
      let find =
        String.trim
          (Build.output [ "exec"; "--"; "sh"; "-c"; "command -v ocamlfind" ])
      in
      List.iter
        (fun (p, forbidden) ->
          let names =
            Process.output ~env:t.env
              [ find; "query"; "-recursive"; "-format"; "%p"; p ]
            |> lines
          in
          require
            (not
               (List.exists
                  (fun n -> n = forbidden || starts ~prefix:(forbidden ^ ".") n)
                  names))
            ("Forbidden runtime in " ^ p))
        [
          ("httpkit-lwt", "eio");
          ("httpkit-oidc-eio", "lwt");
          ("httpkit-cookie", "eio");
          ("httpkit-password", "lwt");
        ];
      print_endline "PASS extension dependency isolation")

let clients () =
  List.iter
    (fun (adapter, runtime, forbidden) ->
      let client = "client_" ^ adapter in
      with_install
        [ "core"; "http1"; "engine"; adapter; "client"; client ]
        [ runtime; "tls-" ^ adapter; "uri"; "mtime.clock.os"; "ipaddr" ]
        (fun t ->
          require
            (not (Sys.file_exists (t.dir / "deps" / forbidden)))
            "Opposite client runtime dependency";
          let c = t.dir / "consumer" in
          project c;
          let call =
            if adapter = "eio" then
              {|Eio_main.run (fun env ->
                let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
                (try Httpkit_client_eio.with_response ~net ~clock ~authenticator "http://x:/"
                  (fun _ _ -> ()); assert false with Invalid_argument _ -> ());
                Httpkit_client_eio.with_pool ~net ~clock ~authenticator "http://localhost/" (fun pool ->
                  let upload = Httpkit_client_eio.upload ~length:0L (fun () -> assert false) in
                  try Httpkit_client_eio.request pool ~meth:Httpkit_core.Method.post ~upload "http://other.invalid/"
                    (fun _ _ -> ()); assert false with Invalid_argument _ -> ()))|}
            else
              {|Lwt_main.run (Lwt.bind
                (Lwt.catch (fun () -> Lwt.bind
                  (Httpkit_client_lwt.with_response ~authenticator "http://x:/" (fun _ _ -> Lwt.return_unit))
                  (fun () -> assert false))
                  (function Invalid_argument _ -> Lwt.return_unit | e -> Lwt.fail e)) (fun () ->
                Httpkit_client_lwt.with_pool ~authenticator "http://localhost/" (fun pool ->
                  let upload = Httpkit_client_lwt.upload ~length:0L (fun () -> assert false) in
                  Lwt.catch (fun () -> Lwt.bind
                    (Httpkit_client_lwt.request pool ~meth:Httpkit_core.Method.post ~upload "http://other.invalid/"
                      (fun _ _ -> Lwt.return_unit)) (fun () -> assert false))
                    (function Invalid_argument _ -> Lwt.return_unit | e -> Lwt.fail e))))|}
          in
          write (c / "consumer.ml")
            ("let () =\n\
              let authenticator = X509.Authenticator.chain_of_trust ~time:(fun \
              () -> None) [] in\n" ^ call
           ^ "; print_endline \"client installed\"\n");
          write (c / "dune")
            (stanza "consumer" ("httpkit-client-" ^ adapter ^ " " ^ runtime));
          require
            (execute t c "consumer" = "client installed\n")
            "Installed client failed";
          write (c / "opposite.ml")
            ("let _ = "
            ^ (if adapter = "eio" then "Lwt.return_unit" else "Eio.Fiber.yield")
            ^ "\n");
          write (c / "dune")
            (stanza ~modules:"opposite" "opposite"
               ("httpkit-client-" ^ adapter));
          check_failure
            (dune t ~check:false c [ "build"; "opposite.exe" ])
            "Unbound module"))
    [ ("eio", "eio_main", "lwt"); ("lwt", "lwt.unix", "eio") ];
  print_endline
    "PASS separately installed native/bytecode clients and opposite-runtime \
     isolation"

let dispatch = function
  | "core" -> basic "core"
  | "middleware" -> basic "middleware"
  | "router" -> basic "router"
  | "protocol" -> protocol ()
  | "adapter" -> adapters ()
  | "framework" -> framework ()
  | "extensions" -> extensions ()
  | "client" -> clients ()
  | name -> fail "Unknown consumer: %s" name
