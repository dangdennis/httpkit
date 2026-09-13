(** Authorization-code/PKCE client. No I/O: the runtime adapter owns HTTP,
    transaction storage, browser binding and one-time callback consumption. *)

type config
type provider
type transaction
type keys
type identity = { issuer : string; subject : string; claims : Yojson.Safe.t }

type error =
  | Invalid_metadata
  | Invalid_keys
  | Invalid_token
  | Unknown_key
  | Expired
  | Invalid_callback

val config :
  ?client_secret:string ->
  ?allow_http_loopback:bool ->
  issuer:string ->
  client_id:string ->
  redirect_uri:string ->
  unit ->
  config
(** HTTPS required, except literal localhost/127.0.0.1/[::1] when explicitly
    enabled for development. Supports client_secret_basic or public-client PKCE.
*)

val discovery_uri : config -> Uri.t
val provider : config -> string -> (provider, error) result
val jwks_uri : provider -> Uri.t

val keys : string -> (keys, error) result
(** Bounded JWKS; RS256 (2048–8192-bit RSA) and ES256 keys only. *)

val begin_login :
  config ->
  provider ->
  now:float ->
  random:(int -> string) ->
  transaction * Uri.t

val state : transaction -> string
val binding : transaction -> string
val expires_at : transaction -> float
val check_binding : transaction -> string -> bool

val callback_code :
  transaction -> now:float -> (string * string) list -> (string, error) result
(** Rejects duplicated fields, mismatched state, provider errors and expired
    flows. *)

type token_request = {
  uri : Uri.t;
  headers : (string * string) list;
  body : string;
}

val token_request :
  config -> provider -> transaction -> code:string -> token_request

val id_token : string -> (string, error) result

val validate :
  config ->
  keys ->
  transaction ->
  now:float ->
  string ->
  (identity, error) result
(** Validates signatures with JOSE, plus exact issuer, audience/azp, nonce,
    expiration, issued-at, optional not-before and algorithm/key policy. *)
