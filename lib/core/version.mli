(** Representable HTTP/1 versions; this does not promise codec support for both.
*)

type t = Http_1_0 | Http_1_1

val to_string : t -> string
