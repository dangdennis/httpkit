module J = Yojson.Safe.Util
module W = Httpkit

type config = {
  issuer : string;
  client_id : string;
  secret : string option;
  redirect : Uri.t;
  loopback : bool;
}

type provider = { authorization : Uri.t; token : Uri.t; jwks : Uri.t }

type transaction = {
  issuer : string;
  state : string;
  binding : string;
  nonce : string;
  verifier : string;
  expires : float;
}

type keys = Jose.Jwk.public Jose.Jwk.t list
type identity = { issuer : string; subject : string; claims : Yojson.Safe.t }

type error =
  | Invalid_metadata
  | Invalid_keys
  | Invalid_token
  | Unknown_key
  | Expired
  | Invalid_callback

let encode = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet

let decode s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
  | Ok v when encode v = s -> Some v
  | _ -> None

let safe_uri ~loopback s =
  if
    String.length s > 4096
    || String.exists
         (fun c -> Char.code c <= 32 || Char.code c >= 127 || c = '\\')
         s
  then invalid_arg "OIDC URL";
  let u = Uri.of_string s in
  if
    Uri.userinfo u <> None
    || Uri.fragment u <> None
    || Uri.host u = None
    || not
         (Uri.scheme u = Some "https"
         || loopback
            && Uri.scheme u = Some "http"
            && List.mem (Uri.host u)
                 [ Some "localhost"; Some "127.0.0.1"; Some "::1" ])
  then invalid_arg "OIDC HTTPS URL";
  u

let config ?client_secret ?(allow_http_loopback = false) ~issuer ~client_id
    ~redirect_uri () =
  let issuer_uri = safe_uri ~loopback:allow_http_loopback issuer in
  let redirect = safe_uri ~loopback:allow_http_loopback redirect_uri in
  if
    Uri.query issuer_uri <> []
    || Uri.query redirect <> []
    || client_id = ""
    || String.length client_id > 1024
    || String.contains client_id '\000'
    || Option.fold ~none:false
         ~some:(fun s ->
           s = "" || String.length s > 4096 || String.contains s '\000')
         client_secret
  then invalid_arg "OIDC configuration";
  {
    issuer;
    client_id;
    secret = client_secret;
    redirect;
    loopback = allow_http_loopback;
  }

let discovery_uri (c : config) =
  Uri.of_string
    ( String.trim c.issuer |> fun s ->
      (if String.ends_with ~suffix:"/" s then
         String.sub s 0 (String.length s - 1)
       else s)
      ^ "/.well-known/openid-configuration" )

let parse limit s = W.Json.parse ~max_bytes:limit ~max_depth:12 s

let provider (c : config) s =
  match parse 65536 s with
  | Error _ -> Error Invalid_metadata
  | Ok j -> (
      try
        if J.(member "issuer" j |> to_string) <> c.issuer then
          Error Invalid_metadata
        else
          let endpoint name =
            safe_uri ~loopback:c.loopback J.(member name j |> to_string)
          in
          let authorization = endpoint "authorization_endpoint"
          and token = endpoint "token_endpoint"
          and jwks = endpoint "jwks_uri" in
          let supports name item =
            match J.member name j with
            | `Null -> true
            | `List xs -> List.mem (`String item) xs
            | _ -> false
          in
          if
            not
              (supports "response_types_supported" "code"
              && supports "code_challenge_methods_supported" "S256"
              && supports "token_endpoint_auth_methods_supported"
                   (if c.secret = None then "none" else "client_secret_basic"))
          then Error Invalid_metadata
          else Ok { authorization; token; jwks }
      with J.Type_error _ | Invalid_argument _ -> Error Invalid_metadata)

let jwks_uri p = p.jwks

let keys s =
  match parse 262144 s with
  | Error _ -> Error Invalid_keys
  | Ok json -> (
      try
        let rows = J.(member "keys" json |> to_list) in
        if rows = [] || List.length rows > 32 then Error Invalid_keys
        else
          let seen = Hashtbl.create 32 in
          let convert row =
            let kid = J.(member "kid" row |> to_string_option) in
            Option.iter
              (fun id ->
                if id = "" || String.length id > 128 || Hashtbl.mem seen id then
                  invalid_arg "duplicate kid"
                else Hashtbl.add seen id ())
              kid;
            let use = J.member "use" row and ops = J.member "key_ops" row in
            let kty = J.member "kty" row and alg = J.member "alg" row in
            let signing = use = `Null || use = `String "sig" in
            let verify =
              ops = `Null
              ||
              match ops with
              | `List xs -> List.mem (`String "verify") xs
              | _ -> false
            in
            let suitable =
              match (kty, alg) with
              | `String "RSA", (`Null | `String "RS256") -> (
                  match J.(member "n" row |> to_string_option) with
                  | Some n -> (
                      match decode n with
                      | Some n ->
                          String.length n >= 256
                          && String.length n <= 1024
                          && Char.code n.[0] >= 128
                      | None -> false)
                  | None -> false)
              | `String "EC", (`Null | `String "ES256") ->
                  J.member "crv" row = `String "P-256"
              | _ -> false
            in
            if not (signing && verify && suitable) then None
            else
              match Jose.Jwk.of_pub_json row with
              | Ok key -> Some key
              | Error _ -> None
          in
          let result = List.filter_map convert rows in
          if result = [] then Error Invalid_keys else Ok result
      with J.Type_error _ | Invalid_argument _ | Failure _ ->
        Error Invalid_keys)

let valid_time n = Float.is_finite n && n >= 0. && n <= 253402300799.

let begin_login (c : config) p ~now ~random =
  if not (valid_time now) then invalid_arg "OIDC clock";
  let fresh () =
    let raw = random 32 in
    if String.length raw <> 32 then invalid_arg "OIDC entropy";
    encode raw
  in
  let t =
    {
      issuer = c.issuer;
      state = fresh ();
      binding = fresh ();
      nonce = fresh ();
      verifier = fresh ();
      expires = now +. 600.;
    }
  in
  let challenge, method_ =
    Oidc.Pkce.(
      Challenge.to_code_challenge_and_method
        (Challenge.make (Verifier.of_string t.verifier)))
  in
  let params =
    Oidc.Parameters.make ~response_type:[ "code" ]
      ~scope:[ `OpenID; `Profile; `Email ]
      ~state:t.state ~nonce:t.nonce ~redirect_uri:c.redirect
      ~client_id:c.client_id ()
  in
  ( t,
    Uri.add_query_params p.authorization
      (Oidc.Parameters.to_query params
      @ [
          ("code_challenge", [ challenge ]);
          ("code_challenge_method", [ method_ ]);
        ]) )

let state t = t.state
let binding t = t.binding
let expires_at t = t.expires
let check_binding t s = Eqaf.equal t.binding s

let callback_code t ~now params =
  let unique name =
    match W.Url.unique name params with Ok v -> v | Error _ -> None
  in
  if (not (valid_time now)) || now >= t.expires then Error Expired
  else if
    List.length params > 16
    || List.exists
         (fun (k, v) -> String.length k > 128 || String.length v > 4096)
         params
    || List.length (List.sort_uniq String.compare (List.map fst params))
       <> List.length params
  then Error Invalid_callback
  else if
    match unique "iss" with None -> false | Some issuer -> issuer <> t.issuer
  then Error Invalid_callback
  else
    match (unique "state", unique "code", unique "error") with
    | Some s, Some code, None when Eqaf.equal s t.state && code <> "" -> Ok code
    | _ -> Error Invalid_callback

type token_request = {
  uri : Uri.t;
  headers : (string * string) list;
  body : string;
}

let token_request c p t ~code =
  if code = "" || String.length code > 4096 then
    invalid_arg "authorization code";
  let fields =
    [
      ("grant_type", "authorization_code");
      ("code", code);
      ("redirect_uri", Uri.to_string c.redirect);
      ("code_verifier", t.verifier);
    ]
  in
  let headers =
    [
      ("content-type", "application/x-www-form-urlencoded");
      ("accept", "application/json");
    ]
  in
  let fields, headers =
    match c.secret with
    | None -> (("client_id", c.client_id) :: fields, headers)
    | Some secret ->
        ( fields,
          ( "authorization",
            "Basic "
            ^ Base64.encode_string
                (W.Url.encode c.client_id ^ ":" ^ W.Url.encode secret) )
          :: headers )
  in
  {
    uri = p.token;
    headers;
    body =
      String.concat "&"
        (List.map (fun (k, v) -> W.Url.encode k ^ "=" ^ W.Url.encode v) fields);
  }

let id_token s =
  match parse 65536 s with
  | Error _ -> Error Invalid_token
  | Ok j when J.member "error" j <> `Null -> Error Invalid_token
  | Ok j -> (
      match J.member "id_token" j with
      | `String s when String.length s <= 32768 && s <> "" -> Ok s
      | _ -> Error Invalid_token)

let validate (c : config) keys t ~now encoded =
  if (not (valid_time now)) || now >= t.expires then Error Expired
  else if String.length encoded > 32768 then Error Invalid_token
  else
    match String.split_on_char '.' encoded with
    | [ h; p; signature ] when signature <> "" -> (
        match (decode h, decode p) with
        | Some header, Some payload -> (
            match (parse 4096 header, parse 24576 payload) with
            | Ok hj, Ok claims -> (
                try
                  let alg = J.(member "alg" hj |> to_string) in
                  let kid = J.(member "kid" hj |> to_string_option) in
                  let forbidden =
                    List.exists
                      (fun name -> J.member name hj <> `Null)
                      [ "crit"; "jwk"; "jku"; "x5u"; "b64" ]
                  in
                  if forbidden || not (List.mem alg [ "RS256"; "ES256" ]) then
                    Error Invalid_token
                  else
                    let candidates =
                      List.filter
                        (fun key ->
                          (kid = None || Jose.Jwk.get_kid key = kid)
                          &&
                          match (alg, Jose.Jwk.get_kty key) with
                          | "RS256", `RSA | "ES256", `EC -> true
                          | _ -> false)
                        keys
                    in
                    match candidates with
                    | [] -> Error Unknown_key
                    | [ _; _ ] -> Error Invalid_token
                    | [ key ] -> (
                        match Jose.Jws.of_string encoded with
                        | Error _ -> Error Invalid_token
                        | Ok jws -> (
                            match Jose.Jws.validate ~jwk:key jws with
                            | Error _ -> Error Invalid_token
                            | Ok _ ->
                                let str name =
                                  J.(member name claims |> to_string)
                                in
                                let number name =
                                  match J.member name claims with
                                  | `Int n when n >= 0 -> float_of_int n
                                  | _ -> raise (Invalid_argument "numeric date")
                                in
                                let issuer = str "iss"
                                and subject = str "sub"
                                and nonce = str "nonce" in
                                let expires = number "exp"
                                and issued = number "iat" in
                                let audience =
                                  match J.member "aud" claims with
                                  | `String s -> [ s ]
                                  | `List xs when List.length xs <= 16 ->
                                      List.map J.to_string xs
                                  | _ -> []
                                in
                                let azp = J.member "azp" claims in
                                let authorized =
                                  azp = `String c.client_id
                                  || (List.length audience = 1 && azp = `Null)
                                in
                                let not_before =
                                  match J.member "nbf" claims with
                                  | `Null -> true
                                  | _ -> number "nbf" <= now +. 60.
                                in
                                if
                                  issuer <> c.issuer || subject = ""
                                  || String.length subject > 256
                                  || (not
                                        (String.for_all
                                           (fun c ->
                                             Char.code c >= 32
                                             && Char.code c < 127)
                                           subject))
                                  || (not (Eqaf.equal nonce t.nonce))
                                  || (not (List.mem c.client_id audience))
                                  || (not authorized) || (not not_before)
                                  || issued > now +. 60.
                                  || now -. issued > 3660.
                                  || expires <= issued
                                then Error Invalid_token
                                else if expires <= now then Error Expired
                                else Ok { issuer; subject; claims }))
                    | _ -> Error Invalid_token
                with J.Type_error _ | Invalid_argument _ | Failure _ ->
                  Error Invalid_token)
            | _ -> Error Invalid_token)
        | _ -> Error Invalid_token)
    | _ -> Error Invalid_token
