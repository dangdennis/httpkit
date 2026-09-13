open Httpkit_core

val make :
  ?status:int -> ?headers:(string * string) list -> string -> string Response.t
(** Owns Content-Length. Conflicting framing headers are rejected. *)

val text : ?status:int -> string -> string Response.t
val html : ?status:int -> string -> string Response.t
val json : ?status:int -> Yojson.Safe.t -> string Response.t
val redirect : ?status:int -> string -> string Response.t
val set_header : string -> string -> 'a Response.t -> 'a Response.t
val header_values : string -> Headers.t -> string list
