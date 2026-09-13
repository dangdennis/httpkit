(** Bounded, single-domain Eio login coordinator. Applications provide their
    HTTPS client: it must validate TLS, refuse redirects, enforce [max_bytes]
    while reading, and support Eio cancellation. No client secrets are logged.
*)

type http_request = {
  meth : [ `GET | `POST ];
  uri : Uri.t;
  headers : (string * string) list;
  body : string;
  max_bytes : int;
}

type http_response = { status : int; body : string }
type t
type error = Busy | Provider_unavailable | Rejected

val create :
  ?capacity:int ->
  ?max_remote:int ->
  ?timeout:float ->
  clock:_ Eio.Time.Mono.t ->
  now:(unit -> float) ->
  random:(int -> string) ->
  http:(http_request -> http_response) ->
  Httpkit_oidc.config ->
  t
(** At most [capacity] pending logins (1024), [max_remote] concurrent remote
    operations (16), and [timeout] seconds per operation (10). Metadata and keys
    refresh automatically. Pending flows live in this process: callbacks must
    return to the same instance. Browser cookies are Secure/HttpOnly/Lax. *)

val start : t -> (Uri.t * string, error) result
(** Authorization URL and Set-Cookie value. Starting a new login in a browser
    supersedes that browser's previous binding cookie. *)

val finish :
  t ->
  cookies:string list ->
  query:(string * string) list ->
  (Httpkit_oidc.identity, error) result
(** Valid browser binding is consumed before token exchange, even on failure. *)

val clear_cookie : string
val login : t -> Httpkit_eio.handler

val callback :
  t ->
  on_login:(Httpkit_oidc.identity -> Httpkit_eio.handler) ->
  Httpkit_eio.handler
