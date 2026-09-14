module C = Httpkit_cookie
module P = Httpkit_password
module O = Httpkit_oidc

let check label b = if not b then failwith label
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let random = Mirage_crypto_rng.generate

let () =
  Mirage_crypto_rng_unix.use_default ();
  let now = ref 1000. in
  let first = C.generate_key ~id:"first"
  and second = C.generate_key ~id:"second" in
  let create ?(name = "__Host-httpkit") keys =
    C.create ~name ~ttl:60 ~now:(fun () -> !now) ~keys ()
  in
  let cookies = create [ first ] in
  let session = ok (C.issue cookies "user-123") in
  check "cookie roundtrip"
    (C.value (ok (C.find cookies (C.token session))) = "user-123");
  check "cookie confidential" (not (String.contains (C.token session) ' '));
  check "csrf"
    (C.check_csrf session (C.csrf session) && not (C.check_csrf session "wrong"));
  let altered = Bytes.of_string (C.token session) in
  Bytes.set altered (Bytes.length altered - 3) '!';
  check "tampered cookie"
    (Result.is_error (C.find cookies (Bytes.to_string altered)));
  for i = 0 to String.length (C.token session) - 1 do
    let tampered = Bytes.of_string (C.token session) in
    Bytes.set tampered i (if Bytes.get tampered i = 'A' then 'B' else 'A');
    check "every cookie byte authenticated"
      (Result.is_error (C.find cookies (Bytes.to_string tampered)))
  done;
  let rotated = create [ second; first ] in
  check "rotation old key"
    (C.needs_refresh rotated (ok (C.find rotated (C.token session))));
  check "retired key"
    (Result.is_error (C.find (create [ second ]) (C.token session)));
  check "application separation"
    (Result.is_error
       (C.find (create ~name:"__Host-other" [ first ]) (C.token session)));
  let headers =
    ok
      (Httpkit_core.Headers.of_list
         [
           ( "cookie",
             "__Host-httpkit=" ^ C.token session ^ "; __Host-httpkit="
             ^ C.token session );
         ])
  in
  check "duplicate credentials" (Result.is_error (C.of_headers cookies headers));
  check "oversize" (C.issue cookies (String.make 2049 'x') = Error C.Too_large);
  now := 1060.;
  check "expiry boundary" (C.find cookies (C.token session) = Error C.Expired);
  let policy = P.create ~memory_kib:19456 ~iterations:2 () in
  let encoded = ok (P.hash policy ~random "correct horse battery staple") in
  check "argon verify"
    (P.verify policy ~encoded "correct horse battery staple" = Ok true);
  check "wrong password" (P.verify policy ~encoded "incorrect" = Ok false);
  check "rehash policy"
    (P.needs_rehash policy encoded = Ok false
    && P.needs_rehash (P.create ()) encoded = Ok true);
  check "cost bomb"
    (P.verify policy
       ~encoded:
         "$argon2id$v=19$m=99999999,t=2,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
       "x"
    = Error P.Invalid_hash);
  check "entropy length"
    (P.hash policy ~random:(fun _ -> "short") "password"
    = Error P.Invalid_entropy);
  check "NUL" (P.verify policy ~encoded "x\000y" = Error P.Invalid_password);
  let private_key =
    Jose.Jwk.make_priv_rsa (Mirage_crypto_pk.Rsa.generate ~bits:2048 ())
  in
  let public = Jose.Jwk.to_pub_json private_key in
  let public =
    match public with
    | `Assoc xs -> `Assoc (("kid", `String "test") :: List.remove_assoc "kid" xs)
    | _ -> assert false
  in
  let keys =
    ok (O.keys (Yojson.Safe.to_string (`Assoc [ ("keys", `List [ public ]) ])))
  in
  let config =
    O.config ~issuer:"https://issuer.example" ~client_id:"client"
      ~redirect_uri:"https://app.example/callback" ()
  in
  let provider =
    ok
      (O.provider config
         {|{"issuer":"https://issuer.example","authorization_endpoint":"https://issuer.example/auth","token_endpoint":"https://issuer.example/token","jwks_uri":"https://issuer.example/jwks"}|})
  in
  let tx, url = O.begin_login config provider ~now:1000. ~random in
  let nonce = Option.get (Uri.get_query_param url "nonce") in
  check "PKCE S256"
    (Uri.get_query_param url "code_challenge_method" = Some "S256");
  check "callback duplicates"
    (Result.is_error
       (O.callback_code tx ~now:1001.
          [ ("state", O.state tx); ("state", O.state tx); ("code", "x") ]));
  let header =
    { (Jose.Header.make_header ~alg:`RS256 private_key) with kid = Some "test" }
  in
  let claims =
    [
      ("iss", `String "https://issuer.example");
      ("sub", `String "user");
      ("aud", `String "client");
      ("nonce", `String nonce);
      ("iat", `Int 1000);
      ("exp", `Int 1200);
    ]
  in
  let sign claims =
    Jose.Jwt.to_string
      (ok (Jose.Jwt.sign ~header ~payload:(`Assoc claims) private_key))
  in
  let token = sign claims in
  check "OIDC verified identity"
    ((ok (O.validate config keys tx ~now:1001. token)).subject = "user");
  let encode =
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
  in
  let h, p, signature =
    match String.split_on_char '.' token with
    | [ h; p; signature ] -> (h, p, signature)
    | _ -> assert false
  in
  let rejected label token =
    check label
      (O.validate config keys tx ~now:1001. token = Error O.Invalid_token)
  in
  let raw_signature =
    ok (Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet signature)
  in
  for i = 0 to String.length raw_signature - 1 do
    let altered = Bytes.of_string raw_signature in
    Bytes.set altered i (Char.chr (Char.code (Bytes.get altered i) lxor 1));
    rejected "every RSA signature byte authenticated"
      (h ^ "." ^ p ^ "." ^ encode (Bytes.to_string altered))
  done;
  let altered_claims =
    `Assoc (("sub", `String "attacker") :: List.remove_assoc "sub" claims)
    |> Yojson.Safe.to_string |> encode
  in
  rejected "changed identity cannot reuse the original signature"
    (h ^ "." ^ altered_claims ^ "." ^ signature);
  List.iter
    (fun alg ->
      let header =
        Yojson.Safe.to_string
          (`Assoc [ ("alg", `String alg); ("kid", `String "test") ])
        |> encode
      in
      rejected "forbidden signature algorithm"
        (header ^ "." ^ p ^ "." ^ signature))
    [ "none"; "HS256" ];
  rejected "empty signature" (h ^ "." ^ p ^ ".");
  List.iter
    (fun (name, value) ->
      let claims = (name, value) :: List.remove_assoc name claims in
      check ("reject claim " ^ name)
        (Result.is_error (O.validate config keys tx ~now:1001. (sign claims))))
    [
      ("iss", `String "https://sts.windows.net/attacker");
      ("aud", `String "other");
      ("nonce", `String "wrong");
      ("iat", `Int 1100);
      ("exp", `Int 1001);
      ("sub", `String "");
      ("azp", `String "other");
      ("nbf", `Int 1300);
    ];
  check "audience array requires azp"
    (Result.is_error
       (O.validate config keys tx ~now:1001.
          (sign
             (("aud", `List [ `String "client"; `String "other" ])
             :: List.remove_assoc "aud" claims))));
  check "duplicate claims"
    (Result.is_error
       (O.validate config keys tx ~now:1001.
          (sign (("iss", `String "https://issuer.example") :: claims))));
  check "duplicate keys"
    (Result.is_error
       (O.keys
          (Yojson.Safe.to_string
             (`Assoc [ ("keys", `List [ public; public ]) ]))));
  check "expired transaction"
    (O.validate config keys tx ~now:1600. token = Error O.Expired);
  print_endline
    "PASS encrypted cookies, rotation, Argon2 policy and strict signed OIDC \
     validation"
