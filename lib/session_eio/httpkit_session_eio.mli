(** Shared PostgreSQL/SQLite sessions. Apply [migration] as part of your ordered
    application migration list before using the store. All operations are scoped
    to the supplied database pool; no background cleanup tasks are created. *)

type t
type session

val migration : version:int -> Httpkit_db_eio.migration

val create :
  ?name:string ->
  ?max_payload:int ->
  namespace:string ->
  ttl:int ->
  now:(unit -> float) ->
  random:(int -> string) ->
  Httpkit_db_eio.t ->
  t
(** [now] is Unix time, [random] supplies cryptographically secure bytes. Tokens
    are stored as SHA-256 digests. A namespace isolates applications. *)

val issue : t -> subject:string -> string -> session

val find : t -> string -> session option
(** Invalid/missing/expired tokens return [None]. A stored subject/value that
    violates issuance constraints, or an invalid stored CSRF token, raises
    [Failure "invalid stored session"] rather than authenticating corrupt data.
    Database errors propagate; the connection remains scoped to the operation.
*)

val rotate : t -> string -> subject:string -> string -> session option
(** Atomic replacement: concurrent attempts using an old token have one winner.
*)

val revoke : t -> string -> unit
val revoke_subject : t -> string -> unit

val prune : ?limit:int -> t -> unit
(** Deletes at most [limit] expired rows per call, default 1000. *)

val value : session -> string
val subject : session -> string
val token : session -> string
val csrf : session -> string
val expires_at : session -> int64
val check_csrf : session -> string -> bool
val of_request : t -> Httpkit_eio.request -> session option
val attach : t -> session -> Httpkit_eio.response -> Httpkit_eio.response

val logout :
  t -> Httpkit_eio.request -> Httpkit_eio.response -> Httpkit_eio.response

val require : t -> (session -> Httpkit_eio.handler) -> Httpkit_eio.handler
val protect_csrf : t -> origins:string list -> Httpkit_eio.middleware
