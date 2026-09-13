type error = Too_large | Too_deep | Invalid_json | Duplicate_key

val parse :
  ?max_bytes:int -> ?max_depth:int -> string -> (Yojson.Safe.t, error) result
(** Bounds nesting before parsing and rejects duplicate object keys. *)
