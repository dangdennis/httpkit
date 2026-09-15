module C = Httpkit_cookie
module P = Httpkit_password
module O = Httpkit_oidc

let check label value = if not value then failwith label

let ok = function
  | Ok value -> value
  | Error _ -> failwith "unexpected rejection"

let invalid f =
  match f () with
  | _ -> failwith "invalid configuration accepted"
  | exception Invalid_argument _ -> ()

let cookies () =
  let key = C.generate_key ~id:"test" in
  check "key export/import preserves identity"
    (C.export_key (C.key ~id:"test" ~secret:(C.export_key key))
    = C.export_key key);
  List.iter
    (fun id -> invalid (fun () -> C.key ~id ~secret:(C.export_key key)))
    [ ""; String.make 33 'a'; "bad.id"; "bad\000id" ];
  List.iter
    (fun size ->
      invalid (fun () -> C.key ~id:"test" ~secret:(String.make size 'x')))
    [ 0; 31; 33 ];
  let now = ref 1000. in
  let create ?(ttl = 60) ?(max_payload = 2048) ?(name = "__Host-test") keys =
    C.create ~ttl ~max_payload ~name ~now:(fun () -> !now) ~keys ()
  in
  List.iter
    (fun ttl -> invalid (fun () -> create ~ttl [ key ]))
    [ 0; -1; 2592001 ];
  List.iter
    (fun max_payload -> invalid (fun () -> create ~max_payload [ key ]))
    [ -1; 2049 ];
  invalid (fun () -> create []);
  invalid (fun () -> create [ key; key ]);
  invalid (fun () -> create ~name:"ordinary" [ key ]);
  invalid (fun () ->
      create (List.init 5 (fun n -> C.generate_key ~id:(string_of_int n))));
  let store = create [ key ] in
  let session = ok (C.issue store "user") in
  check "expiry is absolute" (C.expires_at session = 1060);
  let header value = ok (Httpkit_core.Headers.of_list [ ("cookie", value) ]) in
  check "missing cookie" (C.of_headers store (header "other=value") = Ok None);
  check "malformed cookie"
    (C.of_headers store (header "not-a-pair") = Error C.Invalid);
  check "cookie header extraction"
    (Option.map C.value
       (ok (C.of_headers store (header ("__Host-test=" ^ C.token session))))
    = Some "user");
  let set = C.set_cookie store session in
  check "secure cookie scope"
    (String.starts_with ~prefix:("__Host-test=" ^ C.token session ^ ";") set);
  check "cookie deletion"
    (String.starts_with ~prefix:"__Host-test=;" (C.clear_cookie store));
  check "invalid UTF-8 cannot be issued"
    (C.issue store "\255" = Error C.Too_large);
  check "zero payload limit"
    (C.issue (create ~max_payload:0 [ key ]) "x" = Error C.Too_large);
  check "bounded token input"
    (C.find store (String.make 3801 'x') = Error C.Too_large);
  List.iter
    (fun token ->
      check "invalid token encoding" (C.find store token = Error C.Invalid))
    [ ""; "1.test.AA"; "1.test.!!!"; "2.test.AAAA"; "1.unknown.AA" ];
  (* Upstream AEAD constructs authenticated fixtures. This reaches payload
     validation past tag checking without implementing cryptography ourselves. *)
  let seal payload =
    let nonce = Mirage_crypto_rng.generate 12 in
    let cipher =
      Mirage_crypto.AES.GCM.authenticate_encrypt
        ~key:(Mirage_crypto.AES.GCM.of_secret (C.export_key key))
        ~nonce ~adata:"httpkit-cookie:1:__Host-test:test" payload
    in
    "1.test."
    ^ Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
        (nonce ^ cipher)
  in
  let fields =
    [
      ("iat", `Int 1000);
      ("exp", `Int 1060);
      ("csrf", `String (String.make 43 'a'));
      ("value", `String "user");
    ]
  in
  check "authenticated fixture roundtrip"
    (C.value (ok (C.find store (seal (Yojson.Safe.to_string (`Assoc fields)))))
    = "user");
  List.iter
    (fun (name, value) ->
      let payload =
        Yojson.Safe.to_string
          (`Assoc ((name, value) :: List.remove_assoc name fields))
      in
      check
        ("reject authenticated invalid " ^ name)
        (C.find store (seal payload) = Error C.Invalid))
    [
      ("iat", `Int (-1));
      ("iat", `Int 1001);
      ("exp", `Int 1000);
      ("exp", `Int 1061);
      ("csrf", `String "short");
      ("value", `String (String.make 2049 'x'));
      ("iat", `String "1000");
    ];
  List.iter
    (fun payload ->
      check "reject authenticated malformed JSON"
        (C.find store (seal payload) = Error C.Invalid))
    [ "{"; "[]"; "{}"; "{\"iat\":1000,\"iat\":1000}" ];
  List.iter
    (fun time ->
      now := time;
      invalid (fun () -> C.issue store "user"))
    [ Float.nan; Float.infinity; -1.; 253402300800. ];
  now := 1060.;
  check "expired cookie clears max age"
    (List.mem " Max-Age=0"
       (String.split_on_char ';' (C.set_cookie store session)))

let passwords () =
  List.iter
    (fun memory_kib -> invalid (fun () -> P.create ~memory_kib ()))
    [ 0; 19455; 262145 ];
  List.iter
    (fun iterations -> invalid (fun () -> P.create ~iterations ()))
    [ 0; 1; 11 ];
  let policy = P.create ~memory_kib:19456 ~iterations:2 () in
  let random _ = failwith "invalid password reached entropy/native work" in
  List.iter
    (fun pwd ->
      check "hash password guard"
        (P.hash policy ~random pwd = Error P.Invalid_password);
      check "verify password guard"
        (P.verify policy ~encoded:"invalid" pwd = Error P.Invalid_password))
    [ ""; "x\000y"; String.make 1025 'x' ];
  let encoded ?(salt = String.make 22 'A') ?(digest = String.make 43 'A') params
      =
    "$argon2id$v=19$" ^ params ^ "$" ^ salt ^ "$" ^ digest
  in
  let malformed =
    [
      "";
      String.make 513 'x';
      "\000";
      "$argon2i$v=19$m=19456,t=2,p=1$x$x";
      encoded "m=19456,t=2";
      encoded "m=19456,t=2,p=1,x=1";
      encoded "m=,t=2,p=1";
      encoded "m=999999999,t=2,p=1";
      encoded "m=-1,t=2,p=1";
      encoded "memory=19456,t=2,p=1";
      encoded "m=19456,t=0,p=1";
      encoded "m=19456,t=11,p=1";
      encoded "m=262145,t=2,p=1";
      encoded "m=8,t=1,p=4";
      encoded "m=19456,t=2,p=0";
      encoded "m=19456,t=2,p=5";
      encoded ~salt:"short" "m=19456,t=2,p=1";
      encoded ~salt:(String.make 87 'A') "m=19456,t=2,p=1";
      encoded ~digest:"short" "m=19456,t=2,p=1";
      encoded ~digest:(String.make 87 'A') "m=19456,t=2,p=1";
      encoded ~salt:(String.make 22 '!') "m=19456,t=2,p=1";
    ]
  in
  List.iter
    (fun encoded ->
      check "malformed hash inspection"
        (P.needs_rehash policy encoded = Error P.Invalid_hash);
      check "malformed hash rejects before verification"
        (P.verify policy ~encoded "password" = Error P.Invalid_hash))
    malformed;
  check "weak legacy parameters require rehash"
    (P.needs_rehash policy (encoded "m=8,t=1,p=1") = Ok true)

let oidc () =
  let config ?(issuer = "https://issuer.example") ?(client_id = "client")
      ?client_secret ?(allow_http_loopback = false)
      ?(redirect_uri = "https://app.example/callback") () =
    O.config ~issuer ~client_id ?client_secret ~allow_http_loopback
      ~redirect_uri ()
  in
  List.iter
    (fun issuer -> invalid (fun () -> config ~issuer ()))
    [
      "http://issuer.example";
      "https://user@issuer.example";
      "https://issuer.example/#fragment";
      "https://issuer.example/\000";
      "https://issuer.example/\\x";
      String.make 4097 'x';
    ];
  invalid (fun () -> config ~client_id:"" ());
  invalid (fun () -> config ~client_secret:"" ());
  invalid (fun () -> config ~client_secret:"x\000y" ());
  List.iter
    (fun host ->
      ignore
        (config ~allow_http_loopback:true ~issuer:("http://" ^ host)
           ~redirect_uri:("http://" ^ host ^ "/callback")
           ()))
    [ "localhost"; "127.0.0.1"; "[::1]" ];
  invalid (fun () ->
      config ~allow_http_loopback:true ~issuer:"http://evil.example" ());
  let c = config () in
  let metadata =
    [
      ("issuer", `String "https://issuer.example");
      ("authorization_endpoint", `String "https://issuer.example/auth");
      ("token_endpoint", `String "https://issuer.example/token");
      ("jwks_uri", `String "https://issuer.example/jwks");
    ]
  in
  let provider fields = O.provider c (Yojson.Safe.to_string (`Assoc fields)) in
  let p = ok (provider metadata) in
  List.iter
    (fun (name, value) ->
      check "metadata negotiation rejected"
        (provider ((name, value) :: List.remove_assoc name metadata)
        = Error O.Invalid_metadata))
    [
      ("issuer", `String "https://other.example");
      ("authorization_endpoint", `String "http://issuer.example/auth");
      ("token_endpoint", `Int 42);
      ("response_types_supported", `List [ `String "token" ]);
      ("code_challenge_methods_supported", `List [ `String "plain" ]);
      ("token_endpoint_auth_methods_supported", `String "none");
    ];
  List.iter
    (fun raw ->
      check "malformed metadata" (O.provider c raw = Error O.Invalid_metadata))
    [ "{"; "{}"; String.make 65537 'x' ];
  check "explicit metadata capabilities"
    (Result.is_ok
       (provider
          (("response_types_supported", `List [ `String "code" ]) :: metadata)));
  let tx, _ = O.begin_login c p ~now:1000. ~random:Mirage_crypto_rng.generate in
  List.iter
    (fun query ->
      check "invalid callback fields"
        (O.callback_code tx ~now:1001. query = Error O.Invalid_callback))
    [
      [];
      [ ("state", "wrong"); ("code", "x") ];
      [ ("state", O.state tx); ("error", "access_denied") ];
      [ ("state", O.state tx); ("code", "") ];
    ];
  invalid (fun () -> O.token_request c p tx ~code:"");
  invalid (fun () -> O.token_request c p tx ~code:(String.make 4097 'x'));
  let escaped =
    O.token_request c p tx ~code:"opaque&injected=true+space value"
  in
  let fields = ok (Httpkit.Url.pairs escaped.body) in
  check "opaque code cannot inject form fields"
    (List.assoc "code" fields = "opaque&injected=true+space value"
    && not (List.mem_assoc "injected" fields));
  List.iter
    (fun raw ->
      check "invalid token endpoint payload"
        (O.id_token raw = Error O.Invalid_token))
    [
      "{";
      "{}";
      "{\"id_token\":42}";
      "{\"id_token\":\"\"}";
      String.make 262145 'x';
    ];
  List.iter
    (fun raw ->
      check "invalid key document" (O.keys raw = Error O.Invalid_keys))
    [
      "{";
      "{\"keys\":[]}";
      "{\"keys\":[{\"kty\":\"oct\",\"k\":\"AA\"}]}";
      String.make 262145 'x';
    ]

let () =
  Mirage_crypto_rng_unix.use_default ();
  cookies ();
  passwords ();
  oidc ();
  print_endline
    "PASS cookie payload, password policy and OIDC boundary rejection"
