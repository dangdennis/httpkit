(** A field is one name/value pair, never a comma-joined interpretation. *)

module Name : sig
  type t

  val of_string : ?max_length:int -> string -> (t, Error.t) result
  (** Nonempty ASCII token, normalized to lowercase. Default limit 256 bytes.
      O(n) time and space. Negative limits fail. *)

  val to_string : t -> string
  val equal : t -> t -> bool
end

module Value : sig
  type t

  val of_string : ?max_length:int -> string -> (t, Error.t) result
  (** Default limit 8192 bytes; empty values are valid. Rejects CR, LF, NUL, DEL
      and controls other than interior HTAB. Bytes 0x80..0xff are opaque. As an
      explicit construction policy, leading/trailing SP or HTAB fail; a wire
      parser must remove framing OWS before calling this constructor. O(n) time,
      no input copy. Negative limits fail. *)

  val to_string : t -> string
  val equal : t -> t -> bool
end

type t

val create : Name.t -> Value.t -> t

val of_strings : string -> string -> (t, Error.t) result
(** Uses the default name and value limits. *)

val name : t -> Name.t
val value : t -> Value.t
