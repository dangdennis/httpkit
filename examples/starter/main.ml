module App = Httpkit_eio
module Web = Httpkit
module Db = Httpkit_db_eio

(* Portable statements run unchanged on SQLite and PostgreSQL. For typed
   PostgreSQL queries, generate them with sqlkit and run them on
   [Db.postgresql connection]. *)
module Query = struct
  let insert = "INSERT INTO notes(body) VALUES (?)"
  let list = "SELECT body FROM notes ORDER BY body LIMIT 100"
end

let migration : Db.migration =
  let sql = [ "CREATE TABLE notes (body TEXT NOT NULL)" ] in
  { version = 1; postgresql = sql; sqlite = sql }

let () =
  let uri =
    match Sys.getenv_opt "DATABASE_URL" with
    | Some uri -> Uri.of_string uri
    | None ->
        failwith "Set DATABASE_URL to a file-backed SQLite or PostgreSQL URI"
  in
  let port =
    Option.fold ~none:8080 ~some:int_of_string (Sys.getenv_opt "PORT")
  in
  if port < 0 || port > 65535 then invalid_arg "PORT must be in 0..65535";
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let db =
            Db.create ~sw
              ~stdenv:(env :> Caqti_eio.stdenv)
              ~max_connections:4 ~max_waiters:16 uri
          in
          Fun.protect
            ~finally:(fun () -> Db.close db)
            (fun () ->
              Db.migrate db [ migration ];
              let text ?status body = App.reply (Web.Reply.text ?status body) in
              let handler =
                App.routes
                  ~middleware:[ App.Common.security_headers ]
                  [
                    App.route Httpkit_core.Method.get "/health" (fun _ ->
                        text "ok\n");
                    App.route Httpkit_core.Method.get "/hello/:name"
                      (fun request ->
                        match App.param "name" request with
                        | None -> text ~status:400 "Missing name\n"
                        | Some name -> text ("Hello " ^ name ^ "\n"));
                    App.route Httpkit_core.Method.get "/notes" (fun _ ->
                        let notes =
                          Db.use db (fun connection ->
                              List.filter_map
                                (function
                                  | [ Db.Text body ] -> Some (`String body)
                                  | _ -> None)
                                (Db.query connection ~kinds:[ String ]
                                   Query.list []))
                        in
                        App.reply (Web.Reply.json (`List notes)));
                    App.route Httpkit_core.Method.post "/notes" (fun request ->
                        match App.json request with
                        | Ok (`Assoc [ ("body", `String body) ])
                          when String.trim body <> "" ->
                            Db.transaction db (fun connection ->
                                Db.execute connection Query.insert [ Text body ]);
                            text ~status:201 "Saved\n"
                        | _ ->
                            text ~status:400
                              "Expected a nonempty JSON body field\n");
                  ]
              in
              let socket =
                Eio.Net.listen ~sw ~reuse_addr:true ~backlog:32
                  (Eio.Stdenv.net env)
                  (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
              in
              let stop, notify = Eio.Promise.create ()
              and stopping = ref false in
              let signal _ =
                if not !stopping then (
                  stopping := true;
                  Eio.Promise.resolve notify ())
              in
              let old_term = Sys.signal Sys.sigterm (Sys.Signal_handle signal)
              and old_int = Sys.signal Sys.sigint (Sys.Signal_handle signal) in
              Fun.protect
                ~finally:(fun () ->
                  Sys.set_signal Sys.sigterm old_term;
                  Sys.set_signal Sys.sigint old_int)
                (fun () ->
                  let random n =
                    let bytes = Cstruct.create n in
                    Eio.Flow.read_exact (Eio.Stdenv.secure_random env) bytes;
                    Cstruct.to_string bytes
                  in
                  let actual =
                    match Eio.Net.listening_addr socket with
                    | `Tcp (_, p) -> p
                    | _ -> assert false
                  in
                  Printf.printf "LISTEN %d\n%!" actual;
                  App.serve ~max_connections:16 ~body_limit:4096
                    ~output_limit:32768 ~request_timeout:30.
                    ~clock:(Eio.Stdenv.mono_clock env)
                    ~random ~stop
                    ~accept:(fun () ->
                      let flow, peer = Eio.Net.accept ~sw socket in
                      ( Httpkit_transport_eio.of_flow flow,
                        Format.asprintf "%a" Eio.Net.Sockaddr.pp peer ))
                    ~on_error:(fun _ -> prerr_endline "request failed")
                    handler))))
