(** Persistent bounded fields. Duplicates and insertion order are preserved. No
    implicit merging, sorting, or special handling of Content-Length.
    Message-level framing and authority validation belongs to a codec. *)

type t

val empty : t
(** Default limits: 100 fields and 65536 serialized field bytes. *)

val create : ?max_fields:int -> ?max_bytes:int -> unit -> (t, Error.t) result
(** Nonnegative limits, including zero. Limits travel with the collection. *)

val add : Header.t -> t -> (t, Error.t) result
(** Append in O(1) time and space. Checks limits before retaining the field.
    Byte accounting is name + colon/SP + value + CRLF per field, excluding the
    final empty line. It is accounting, not a serializer. *)

val of_list :
  ?max_fields:int ->
  ?max_bytes:int ->
  (string * string) list ->
  (t, Error.t) result
(** Validate using default per-field limits, then append in list order. O(total
    bytes). *)

val to_list : t -> Header.t list
(** Insertion order; O(number of fields) time and space. *)

val get_all : Header.Name.t -> t -> Header.Value.t list
(** Every matching value in insertion order; O(number of fields) time. *)

val length : t -> int
val wire_bytes : t -> int
