(** Encrypted, authenticated cookie sessions using Mirage_crypto AES-GCM.
    Initialize Mirage_crypto_rng in the application before issuing sessions.
    Cookies are replayable until expiry; immediate revocation needs server
    state. Use independent keys per application and rotate well before 2^32
    issues/key. *)

type key

val key : id:string -> secret:string -> key
(** Exactly 32 secret bytes from a CSPRNG. IDs are public, at most 32 URL-safe
    bytes. *)

val generate_key : id:string -> key

val export_key : key -> string
(** Secret material; store outside source control. *)

type t
type session
type error = Invalid | Expired | Too_large

val create :
  ?name:string ->
  ?max_payload:int ->
  ttl:int ->
  now:(unit -> float) ->
  keys:key list ->
  unit ->
  t
(** First key issues cookies; up to four keys can read cookies during rotation.
    [now] is Unix time in seconds. [ttl] is at most 30 days. *)

val issue : t -> string -> (session, error) result
val find : t -> string -> (session, error) result
val of_headers : t -> Httpkit_core.Headers.t -> (session option, error) result
val value : session -> string
val token : session -> string
val csrf : session -> string
val expires_at : session -> int
val needs_refresh : t -> session -> bool
val check_csrf : session -> string -> bool
val set_cookie : t -> session -> string
val clear_cookie : t -> string
