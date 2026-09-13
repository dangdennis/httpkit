(** Strict byte-oriented decoding. No implicit path normalization. *)

type error = Invalid_escape | Invalid_byte | Limit | Duplicate

val decode :
  ?plus:bool ->
  ?allow_newlines:bool ->
  ?max_bytes:int ->
  string ->
  (string, error) result

val encode : string -> string

val pairs :
  ?max_bytes:int ->
  ?max_fields:int ->
  string ->
  ((string * string) list, error) result
(** Form/query semantics: '+' is space; order and duplicates are retained. *)

val query :
  ?max_bytes:int ->
  ?max_fields:int ->
  string ->
  ((string * string) list, error) result

val unique : string -> (string * string) list -> (string option, error) result

val path_segments : ?max_bytes:int -> string -> (string list, error) result
(** Reject decoded separators, dot segments, NUL, controls and backslashes. *)
