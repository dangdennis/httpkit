(** Bounded single-domain, in-memory sessions. Synchronize operations if
    callbacks may yield. Use a shared store for multiple processes or durable
    logins. *)

type 'a t
type 'a session

val create :
  ?capacity:int ->
  ttl:float ->
  now:(unit -> float) ->
  random:(int -> string) ->
  unit ->
  'a t
(** [now] must be monotonic; [random] must provide cryptographic random bytes.
    Issuance requires a finite expiry strictly later than [now]. Unrepresentable
    clock-plus-TTL values raise [Invalid_argument] before consuming entropy or
    inserting a session. Failed rotation restores the previous session. *)

val issue : 'a t -> 'a -> ('a session, string) result
val find : 'a t -> string -> 'a session option
val revoke : 'a t -> string -> unit
val rotate : 'a t -> 'a session -> 'a -> ('a session, string) result
val token : 'a session -> string
val csrf : 'a session -> string
val value : 'a session -> 'a
val check_csrf : 'a session -> string -> bool
val count : 'a t -> int
