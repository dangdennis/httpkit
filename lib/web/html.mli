type t

val text : string -> t

val element : ?attrs:(string * string) list -> string -> t list -> t
(** Escapes text and quoted attributes. Rejects event/style attributes and
    unsafe URL schemes. Script/style contents and raw markup are intentionally
    unavailable. *)

val render : t -> string
