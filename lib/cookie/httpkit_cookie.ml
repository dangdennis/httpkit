module G = Mirage_crypto.AES.GCM
module W = Httpkit
module J = Yojson.Safe.Util

type key = { id : string; secret : string; cipher : G.key }

let valid_id s =
  String.length s > 0
  && String.length s <= 32
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true | _ -> false)
       s

let key ~id ~secret =
  if (not (valid_id id)) || String.length secret <> 32 then
    invalid_arg "cookie key";
  { id; secret; cipher = G.of_secret secret }

let generate_key ~id = key ~id ~secret:(Mirage_crypto_rng.generate 32)
let export_key k = k.secret

type t = {
  name : string;
  max_payload : int;
  ttl : int;
  now : unit -> float;
  keys : key list;
}

type session = {
  value : string;
  token : string;
  csrf : string;
  expires : int;
  kid : string;
}

type error = Invalid | Expired | Too_large

let encode = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet

let decode s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
  | Ok v when encode v = s -> Some v
  | _ -> None

let create ?(name = "__Host-httpkit") ?(max_payload = 2048) ~ttl ~now ~keys () =
  if
    ttl <= 0 || ttl > 2592000 || max_payload < 0 || max_payload > 2048
    || keys = []
    || List.length keys > 4
    || (not (String.starts_with ~prefix:"__Host-" name))
    || List.length
         (List.sort_uniq String.compare (List.map (fun k -> k.id) keys))
       <> List.length keys
  then invalid_arg "cookie session configuration";
  ignore (W.Cookie.set name "");
  { name; max_payload; ttl; now; keys }

let now t =
  let n = t.now () in
  if (not (Float.is_finite n)) || n < 0. || n > 253402300799. then
    invalid_arg "cookie clock";
  int_of_float n

let value s = s.value
let token s = s.token
let csrf s = s.csrf
let expires_at s = s.expires
let check_csrf s candidate = Eqaf.equal s.csrf candidate
let needs_refresh t s = s.kid <> (List.hd t.keys).id
let adata t kid = "httpkit-cookie:1:" ^ t.name ^ ":" ^ kid

let issue t value =
  if String.length value > t.max_payload || not (String.is_valid_utf_8 value)
  then Error Too_large
  else
    let k = List.hd t.keys and issued = now t in
    let expires = issued + t.ttl in
    let csrf = encode (Mirage_crypto_rng.generate 32) in
    let payload =
      Yojson.Safe.to_string
        (`Assoc
           [
             ("iat", `Int issued);
             ("exp", `Int expires);
             ("csrf", `String csrf);
             ("value", `String value);
           ])
    in
    let nonce = Mirage_crypto_rng.generate 12 in
    let ciphertext =
      G.authenticate_encrypt ~key:k.cipher ~nonce ~adata:(adata t k.id) payload
    in
    let token = "1." ^ k.id ^ "." ^ encode (nonce ^ ciphertext) in
    if String.length token > 3800 then Error Too_large
    else Ok { value; token; csrf; expires; kid = k.id }

let find t token =
  if String.length token > 3800 then Error Too_large
  else
    match String.split_on_char '.' token with
    | [ "1"; kid; encoded ] -> (
        match (List.find_opt (fun k -> k.id = kid) t.keys, decode encoded) with
        | Some k, Some raw when String.length raw >= 28 -> (
            let nonce = String.sub raw 0 12
            and ciphertext = String.sub raw 12 (String.length raw - 12) in
            match
              G.authenticate_decrypt ~key:k.cipher ~nonce ~adata:(adata t kid)
                ciphertext
            with
            | None -> Error Invalid
            | Some payload -> (
                match W.Json.parse ~max_bytes:3800 ~max_depth:3 payload with
                | Error _ -> Error Invalid
                | Ok json -> (
                    try
                      let issued = J.(member "iat" json |> to_int)
                      and expires = J.(member "exp" json |> to_int) in
                      let csrf = J.(member "csrf" json |> to_string)
                      and value = J.(member "value" json |> to_string) in
                      let current = now t in
                      if
                        issued < 0 || issued > current || expires <= issued
                        || expires - issued > t.ttl
                        || String.length value > t.max_payload
                        || String.length csrf <> 43
                      then Error Invalid
                      else if expires <= current then Error Expired
                      else Ok { value; token; csrf; expires; kid }
                    with J.Type_error _ -> Error Invalid)))
        | _ -> Error Invalid)
    | _ -> Error Invalid

let of_headers t headers =
  match W.Cookie.parse (W.Reply.header_values "cookie" headers) with
  | Error _ -> Error Invalid
  | Ok cookies -> (
      match W.Cookie.find t.name cookies with
      | Error _ -> Error Invalid
      | Ok None -> Ok None
      | Ok (Some token) -> Result.map Option.some (find t token))

let set_cookie t s =
  W.Cookie.set ~max_age:(max 0 (s.expires - now t)) t.name s.token

let clear_cookie t = W.Cookie.set ~max_age:0 t.name ""
