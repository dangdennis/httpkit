open Httpkit_core
module W = Httpkit
module App = Httpkit_eio
module Db = Httpkit_db_eio

let () =
  let max_connections =
    Config.max_connections (Sys.getenv_opt "HTTPKIT_MAX_CONNECTIONS")
  in
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let clock = Eio.Stdenv.mono_clock env in
          let metrics = Metrics.create () in
          let testing = Sys.getenv_opt "FRAMEWORK_TEST_MODE" = Some "1" in
          let random n =
            let b = Cstruct.create n in
            Eio.Flow.read_exact (Eio.Stdenv.secure_random env) b;
            Cstruct.to_string b
          in
          let sessions = App.Sessions.create ~ttl:3600. ~clock ~random () in
          let db =
            Option.map
              (fun uri ->
                Db.create ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  (Uri.of_string uri))
              (Sys.getenv_opt "DATABASE_URL")
          in
          let static_name =
            Option.value ~default:"public" (Sys.getenv_opt "STATIC_ROOT")
          in
          let static_root =
            Eio.Path.(
              (if Filename.is_relative static_name then Eio.Stdenv.cwd env
               else Eio.Stdenv.fs env)
              / static_name)
          in
          let origins =
            match Sys.getenv_opt "APP_ORIGIN" with
            | Some s -> [ s ]
            | None -> [ "https://localhost" ]
          in
          let text ?status s = App.reply (W.Reply.text ?status s) in
          let handler =
            App.routes
              ~middleware:
                [
                  App.Common.security_headers;
                  App.Common.cors ~origins ~methods:[ "GET"; "POST" ]
                    ~headers:[ "content-type"; "x-csrf-token" ]
                    ~credentials:true ();
                ]
              [
                App.route Method.get "/stats" (fun _ ->
                    if testing then
                      App.reply (W.Reply.json (Metrics.snapshot metrics))
                    else text ~status:404 "Not found\n");
                App.route Method.get "/health" (fun _ -> text "ok\n");
                App.route Method.get "/bench-stats" (fun _ ->
                    if testing then
                      App.reply
                        (W.Reply.json (Metrics.counters ~max_connections ()))
                    else text ~status:404 "Not found\n");
                App.route Method.get "/plaintext" (fun _ ->
                    text "Hello, world!\n");
                App.route Method.get "/json" (fun _ ->
                    App.reply
                      (W.Reply.json
                         (`Assoc [ ("message", `String "Hello, world!") ])));
                App.route Method.post "/echo" (fun request ->
                    App.reply
                      (W.Reply.make
                         ~headers:
                           [ ("content-type", "application/octet-stream") ]
                         (App.body request)));
                App.route Method.get "/small-stream" (fun _ ->
                    App.stream (fun send ->
                        for _ = 1 to 4 do
                          send (String.make 1024 's')
                        done));
                App.route Method.get "/large-stream" (fun _ ->
                    App.stream (fun send ->
                        for _ = 1 to 128 do
                          send (String.make 8192 'x')
                        done));
                App.route Method.get "/" (fun _ ->
                    App.reply
                      (W.Reply.html
                         (W.Html.render
                            (W.Html.element "main"
                               [
                                 W.Html.element "h1" [ W.Html.text "httpkit" ];
                                 W.Html.text "Eio framework example";
                               ]))));
                App.route Method.post "/json" (fun request ->
                    match App.json request with
                    | Ok json -> App.reply (W.Reply.json json)
                    | Error _ -> text ~status:400 "Invalid JSON\n");
                App.route Method.post "/form" (fun request ->
                    match App.form request with
                    | Ok fields ->
                        App.reply
                          (W.Reply.json
                             (`Assoc
                                (List.map (fun (k, v) -> (k, `String v)) fields)))
                    | Error _ -> text ~status:400 "Invalid form\n");
                App.route Method.post "/upload" (fun request ->
                    match
                      W.Reply.header_values "content-type"
                        (Request.headers (App.head request))
                    with
                    | [ header ] -> (
                        match W.Multipart.boundary header with
                        | Error _ -> text ~status:400 "Invalid multipart\n"
                        | Ok boundary -> (
                            let count = ref 0 in
                            let parser =
                              W.Multipart.create ~boundary (function
                                | W.Multipart.Data s ->
                                    count := !count + String.length s
                                | _ -> ())
                            in
                            match App.multipart request parser with
                            | Ok () -> text (string_of_int !count)
                            | Error _ -> text ~status:400 "Invalid multipart\n")
                        )
                    | _ -> text ~status:400 "Content-Type required\n");
                App.route Method.get "/stream" (fun _ ->
                    App.stream (fun send ->
                        for _ = 1 to 128 do
                          send (String.make 8192 'x')
                        done));
                App.route Method.get "/events" (fun _ ->
                    App.Realtime.sse (fun send ->
                        for i = 1 to 3 do
                          send
                            (Result.get_ok
                               (W.Sse.event ~id:(string_of_int i)
                                  ("event " ^ string_of_int i)))
                        done));
                App.route Method.get "/ws" (fun request ->
                    App.websocket ~allowed_origins:origins request
                      (fun transport suffix ->
                        App.Realtime.websocket ~clock transport suffix (function
                          | W.Websocket.Text s -> Some (W.Websocket.Text s)
                          | _ -> None)));
                App.route Method.get "/static/*path" (fun request ->
                    let path =
                      Option.value ~default:"" (App.param "path" request)
                    in
                    App.Files.static ~root:static_root ("/" ^ path) request);
                App.route Method.get "/db" (fun _ ->
                    match db with
                    | None -> text ~status:503 "Database not configured\n"
                    | Some db ->
                        let open Caqti.Templater in
                        let query = static T.(unit -->! int) "SELECT 1" in
                        let n =
                          Db.use db (fun (module C : Caqti_eio.CONNECTION) ->
                              Caqti_eio.or_fail (C.find query ()))
                        in
                        text (string_of_int n));
                App.route Method.post "/login" (fun request ->
                    (* The application supplies token verification; no default login credential. *)
                    let verify token =
                      match Sys.getenv_opt "DEMO_LOGIN_TOKEN" with
                      | Some expected when Eqaf.equal expected token ->
                          Some "demo"
                      | _ -> None
                    in
                    match
                      W.Auth.authenticate ~verify
                        (Request.headers (App.head request))
                    with
                    | Ok (Some user) ->
                        App.Sessions.login sessions user (text "Signed in\n")
                    | _ -> text ~status:401 "Authentication required\n");
                App.route Method.get "/session"
                  (App.Sessions.require sessions (fun session _ ->
                       App.reply
                         (W.Reply.json
                            (`Assoc
                               [
                                 ("user", `String (W.Session.value session));
                                 ("csrf", `String (W.Session.csrf session));
                               ]))));
                App.route Method.post "/logout"
                  (App.Sessions.csrf sessions ~origins (fun request ->
                       App.Sessions.logout sessions request
                         (text "Signed out\n")));
                App.route Method.get "/error" (fun _ ->
                    failwith "example error");
              ]
          in
          let port =
            Option.fold ~none:8080 ~some:int_of_string (Sys.getenv_opt "PORT")
          in
          if port < 0 || port > 65535 then invalid_arg "PORT";
          let socket =
            Eio.Net.listen ~sw ~reuse_addr:true
              ~backlog:(max 32 max_connections) (Eio.Stdenv.net env)
              (`Tcp (Eio.Net.Ipaddr.V4.any, port))
          in
          let stop, notify = Eio.Promise.create () and signalled = ref false in
          let signal _ =
            if not !signalled then (
              signalled := true;
              Eio.Promise.resolve notify ())
          in
          let old_term = Sys.signal Sys.sigterm (Sys.Signal_handle signal)
          and old_int = Sys.signal Sys.sigint (Sys.Signal_handle signal) in
          Fun.protect
            ~finally:(fun () ->
              Sys.set_signal Sys.sigterm old_term;
              Sys.set_signal Sys.sigint old_int;
              Option.iter Db.close db)
            (fun () ->
              let actual =
                match Eio.Net.listening_addr socket with
                | `Tcp (_, p) -> p
                | _ -> assert false
              in
              Printf.printf "LISTEN %d\n%!" actual;
              App.serve ~max_connections ~clock ~random ~stop
                ~accept:(fun () ->
                  let flow, peer = Eio.Net.accept ~sw socket in
                  ( Metrics.transport metrics
                      (Httpkit_transport_eio.of_flow flow),
                    Format.asprintf "%a" Eio.Net.Sockaddr.pp peer ))
                ~on_error:(fun exn ->
                  Metrics.error metrics exn;
                  prerr_endline "connection or application failure")
                handler;
              if testing then (
                print_endline (Yojson.Safe.to_string (Metrics.snapshot metrics));
                if metrics.opened <> metrics.closed || metrics.unexpected <> 0
                then failwith "framework cleanup failure"))))
