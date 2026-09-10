type t
(** Three-digit HTTP status codes in 100..599, including extension codes. *)

val of_int : int -> (t, Error.t) result
val to_int : t -> int
val equal : t -> t -> bool
val continue : t
val ok : t
val no_content : t
val not_modified : t
val bad_request : t
val not_found : t
val internal_server_error : t
