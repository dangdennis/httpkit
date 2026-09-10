(** Case-sensitive HTTP method tokens (RFC 9110, sections 5.6.2 and 9.1). *)

type t

val of_string : ?max_length:int -> string -> (t, Error.t) result
(** Nonempty ASCII token; default limit 64 bytes. Negative limits fail.
    Extension methods and their case are preserved. O(n) time, no input copy. *)

val to_string : t -> string
val equal : t -> t -> bool
val get : t
val head : t
val post : t
val put : t
val delete : t
val connect : t
val options : t
val trace : t
val patch : t
