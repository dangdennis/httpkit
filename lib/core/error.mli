(** Bounded diagnostics. Errors never retain untrusted input. Offsets count
    bytes. *)

type component =
  | Method
  | Header_name
  | Header_value
  | Headers
  | Target
  | Status

type reason =
  | Empty
  | Invalid_byte
  | Invalid_escape
  | Surrounding_whitespace
  | Too_long
  | Too_many_fields
  | Invalid_limit
  | Out_of_range

type t = { component : component; reason : reason; offset : int option }

val to_string : t -> string
(** A stable category description suitable for logs, without the offending
    input. *)
