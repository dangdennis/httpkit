module O = Httpkit_oidc
module A = Httpkit_oidc_eio

let check label b = if not b then failwith label
let ok = function Ok x -> x | Error _ -> failwith "unexpected OIDC error"

let () =
  Mirage_crypto_rng_unix.use_default ();
  let private_key =
    Jose.Jwk.make_priv_rsa (Mirage_crypto_pk.Rsa.generate ~bits:2048 ())
  in
  let header =
    { (Jose.Header.make_header ~alg:`RS256 private_key) with kid = Some "test" }
  in
  let public =
    match Jose.Jwk.to_pub_json private_key with
    | `Assoc xs -> `Assoc (("kid", `String "test") :: List.remove_assoc "kid" xs)
    | _ -> assert false
  in
  let jwks = Yojson.Safe.to_string (`Assoc [ ("keys", `List [ public ]) ]) in
  Eio_main.run (fun env ->
      let now = ref 1000.
      and nonce = ref ""
      and posts = ref 0
      and gets = ref 0 in
      let http (r : A.http_request) =
        match (r.meth, Uri.path r.uri) with
        | `GET, "/.well-known/openid-configuration" ->
            incr gets;
            {
              A.status = 200;
              body =
                {|{"issuer":"https://issuer.example","authorization_endpoint":"https://issuer.example/auth","token_endpoint":"https://issuer.example/token","jwks_uri":"https://issuer.example/jwks"}|};
            }
        | `GET, "/jwks" ->
            incr gets;
            { A.status = 200; body = jwks }
        | `POST, "/token" ->
            incr posts;
            let fields = ok (Httpkit.Url.pairs r.body) in
            check "PKCE verifier sent"
              (String.length
                 (Option.get (List.assoc_opt "code_verifier" fields))
              = 43);
            check "public client id sent"
              (List.assoc_opt "client_id" fields = Some "client");
            let token =
              Jose.Jwt.to_string
                (ok
                   (Jose.Jwt.sign ~header
                      ~payload:
                        (`Assoc
                           [
                             ("iss", `String "https://issuer.example");
                             ("sub", `String "user");
                             ("aud", `String "client");
                             ("nonce", `String !nonce);
                             ("iat", `Int 1000);
                             ("exp", `Int 1500);
                           ])
                      private_key))
            in
            {
              A.status = 200;
              body =
                Yojson.Safe.to_string (`Assoc [ ("id_token", `String token) ]);
            }
        | _ -> failwith "unexpected provider request"
      in
      let config =
        O.config ~issuer:"https://issuer.example" ~client_id:"client"
          ~redirect_uri:"https://app.example/callback" ()
      in
      let client =
        A.create ~capacity:2 ~max_remote:2
          ~clock:(Eio.Stdenv.mono_clock env)
          ~now:(fun () -> !now)
          ~random:Mirage_crypto_rng.generate ~http config
      in
      let url, cookie = ok (A.start client) in
      nonce := Option.get (Uri.get_query_param url "nonce");
      let cookies = [ List.hd (String.split_on_char ';' cookie) ]
      and query =
        [
          ("state", Option.get (Uri.get_query_param url "state"));
          ("code", "code");
        ]
      in
      check "browser binding"
        (A.finish client ~cookies:[ "__Host-httpkit-oidc=wrong" ] ~query
         = Error A.Rejected
        && !posts = 0);
      check "login identity"
        ((ok (A.finish client ~cookies ~query)).subject = "user");
      check "replay rejected"
        (A.finish client ~cookies ~query = Error A.Rejected && !posts = 1);
      check "metadata cached" (!gets = 2);
      ignore (ok (A.start client));
      ignore (ok (A.start client));
      check "bounded pending flows" (A.start client = Error A.Busy);
      now := 1700.;
      ignore (ok (A.start client));
      let slow =
        A.create ~timeout:0.01
          ~clock:(Eio.Stdenv.mono_clock env)
          ~now:(fun () -> !now)
          ~random:Mirage_crypto_rng.generate
          ~http:(fun _ -> Eio.Fiber.await_cancel ())
          config
      in
      check "provider timeout" (A.start slow = Error A.Provider_unavailable);
      now := 1000.;
      let client =
        A.create
          ~clock:(Eio.Stdenv.mono_clock env)
          ~now:(fun () -> !now)
          ~random:Mirage_crypto_rng.generate ~http config
      in
      Eio.Switch.run (fun sw ->
          let module App = Httpkit_eio in
          let module Transport = Httpkit_transport_eio in
          let module Engine = Httpkit_engine in
          let open Httpkit_core in
          let server, peer = Eio_unix.Net.socketpair_stream ~sw () in
          let stop, notify = Eio.Promise.create () in
          let accepted = ref false in
          let application =
            App.routes
              [
                App.route Method.get "/login" (A.login client);
                App.route Method.get "/callback"
                  (A.callback client ~on_login:(fun identity _ ->
                       App.reply (Httpkit.Reply.text identity.subject)));
              ]
          in
          Eio.Fiber.both
            (fun () ->
              App.serve ~max_connections:1
                ~clock:(Eio.Stdenv.mono_clock env)
                ~random:Mirage_crypto_rng.generate ~stop
                ~accept:(fun () ->
                  if !accepted then Eio.Fiber.await_cancel ();
                  accepted := true;
                  (Transport.of_flow server, "local"))
                ~on_error:raise application)
            (fun () ->
              Fun.protect
                ~finally:(fun () -> Eio.Promise.resolve notify ())
                (fun () ->
                  Transport.with_connection
                    ~clock:(Eio.Stdenv.mono_clock env)
                    (Transport.of_flow peer)
                    (ok (Engine.client ()))
                    (fun connection ->
                      let get ?(headers = []) path =
                        let request =
                          Request.create ~meth:Method.get
                            ~target:(ok (Target.of_string path))
                            ~headers:
                              (ok
                                 (Headers.of_list
                                    (("host", "app.example") :: headers)))
                            ()
                        in
                        let id = Transport.submit_request connection request in
                        Transport.finish connection id;
                        match Transport.next_event connection with
                        | Engine.Response (_, response) ->
                            let body, _ =
                              Transport.collect_body connection id
                            in
                            (response, body)
                        | _ -> failwith "missing OIDC HTTP response"
                      in
                      let response, _ = get "/login" in
                      check "provider redirect"
                        (Status.to_int (Response.status response) = 303);
                      let headers = Response.headers response in
                      let url =
                        Uri.of_string
                          (List.hd
                             (Httpkit.Reply.header_values "location" headers))
                      in
                      check "provider redirect URL"
                        (Uri.host url = Some "issuer.example");
                      nonce := Option.get (Uri.get_query_param url "nonce");
                      let cookie =
                        List.hd
                          (Httpkit.Reply.header_values "set-cookie" headers)
                        |> String.split_on_char ';' |> List.hd
                      in
                      let callback =
                        "/callback?state="
                        ^ Option.get (Uri.get_query_param url "state")
                        ^ "&code=code"
                      in
                      let response, body =
                        get ~headers:[ ("cookie", cookie) ] callback
                      in
                      check "HTTP login callback"
                        (Status.to_int (Response.status response) = 200
                        && body = "user");
                      check "binding cookie cleared"
                        (Httpkit.Reply.header_values "set-cookie"
                           (Response.headers response)
                        = [ A.clear_cookie ]);
                      let response, _ =
                        get ~headers:[ ("cookie", cookie) ] callback
                      in
                      check "HTTP replay denied"
                        (Status.to_int (Response.status response) = 400))))));
  print_endline
    "PASS generic OIDC coordinator, browser binding, replay rejection, \
     caching, capacity and timeout"
