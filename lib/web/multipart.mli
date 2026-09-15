(** Strict streaming multipart/form-data. No preamble or epilogue. [filename] is
    metadata, never a filesystem path. Header controls are rejected before
    whitespace normalization; only SP/HTAB are optional value whitespace.
    Callback failure is terminal. *)

type part = {
  name : string;
  filename : string option;
  headers : Httpkit_core.Headers.t;
}

type event = Begin of part | Data of string | End
type t

val create :
  ?max_header_bytes:int ->
  ?max_parts:int ->
  ?max_part_bytes:int ->
  ?max_total_bytes:int ->
  boundary:string ->
  (event -> unit) ->
  t

val feed : t -> string -> (unit, string) result
(** Input chunks are at most 64 KiB. Retained delimiter/header state is bounded.
*)

val finish : t -> (unit, string) result
val boundary : string -> (string, string) result
val retained_bytes : t -> int
