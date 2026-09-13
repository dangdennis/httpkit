(** Argon2id policy wrapper. Calls are synchronous and memory intensive: execute
    them in a bounded worker pool, never directly in a request event loop. At
    most 256 MiB and 10 iterations are accepted from stored hashes. *)

type t
type error = Invalid_password | Invalid_hash | Invalid_entropy | Backend_error

val create : ?memory_kib:int -> ?iterations:int -> unit -> t
(** Defaults: 64 MiB, three iterations, one lane, 16-byte salt, 32-byte hash. *)

val hash : t -> random:(int -> string) -> string -> (string, error) result
(** [random] must return cryptographically secure bytes. Passwords are bounded
    to 1024 bytes; embedded NUL bytes are rejected. *)

val verify : t -> encoded:string -> string -> (bool, error) result

val needs_rehash : t -> string -> (bool, error) result
(** Inspect policy after successful verification; this does not authenticate a
    hash. *)
