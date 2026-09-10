(** Lexical request-target tokens, not a full URI or request-target-form parser.
*)

type t

val of_string : ?max_length:int -> string -> (t, Error.t) result
(** Nonempty URI-character token with valid percent triplets; default 8192
    bytes. Rejects whitespace, controls, non-ASCII, backslash and fragments.
    Preserves bytes exactly: never decodes escapes, folds case, or normalizes
    paths. A codec must additionally check target form, method, authority and
    Host. This value is not a safe filesystem path. O(n) time, no input copy. *)

val to_string : t -> string
val equal : t -> t -> bool
