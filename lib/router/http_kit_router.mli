open Http_kit_core
(** Bounded routing over raw origin-form request targets. No I/O, decoding,
    redirects, handler invocation, or response construction. *)

type error =
  | Invalid_pattern
  | Invalid_limit
  | Too_many_routes
  | Target_limit
  | Segment_limit
  | Unsupported_target

val error_to_string : error -> string

type pattern

val pattern :
  ?max_bytes:int -> ?max_segments:int -> string -> (pattern, error) result
(** A leading slash followed by literal segments, [:name] parameters, or a final
    [*name] wildcard. Defaults: 4096 bytes and 64 segments. Names are ASCII
    identifiers and unique within the pattern. Query strings are forbidden.
    Parameters consume one nonempty segment. A wildcard consumes zero or more
    remaining segments. Repeated/trailing slashes and percent escapes are
    literal; no decoding, case folding or dot-segment normalization occurs. *)

module Params : sig
  type t

  val find : string -> t -> string option

  val to_list : t -> (string * string) list
  (** Raw encoded captures in pattern order. A wildcard uses slash-separated
      remaining segments; its empty capture is [""]. Captures are not validated
      filesystem paths or decoded identifiers. *)
end

type 'a route

val route : meth:Method.t -> pattern -> 'a -> 'a route
(** Associate application data with a method and pattern. Data may be a handler,
    but the router does not execute it. *)

type 'a t

val compile :
  ?max_routes:int ->
  ?max_target_bytes:int ->
  ?max_segments:int ->
  'a route list ->
  ('a t, error) result
(** Defaults: 1024 routes, 8192 bytes per target (including query), 64 path
    segments. Limits must be nonnegative; pattern limits must be positive.
    Copies a bounded route list into an immutable table. Matching is a bounded
    linear scan in declaration order, not a regular-expression engine or trie.
*)

type 'a matched = { value : 'a; params : Params.t }

type 'a outcome =
  | Matched of 'a matched
  | Not_found
  | Method_not_allowed of Method.t list

val lookup :
  'a t -> meth:Method.t -> target:Target.t -> ('a outcome, error) result
(** First matching method/path wins. When paths match but methods do not, return
    distinct allowed methods in declaration order. HEAD is not implicitly GET;
    OPTIONS and the Allow header are application policies.

    Only origin-form targets starting with [/] are accepted. Query bytes do not
    participate in matching. Absolute-form, authority-form and [*] targets need
    explicit application handling. The path is split once; bounded table and
    segment counts cap matching work. Overlapping patterns are allowed, so place
    specific routes before broader routes when that precedence is intended. *)
