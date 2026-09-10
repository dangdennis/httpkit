(** Immutable request metadata. Body ownership and lifetime belong to the
    caller. Typed fields prevent lexical injection; combinations still need
    codec validation. *)

type 'body t

val create :
  ?version:Version.t ->
  ?headers:Headers.t ->
  meth:Method.t ->
  target:Target.t ->
  'body ->
  'body t
(** Defaults to HTTP/1.1 and empty headers. Does not infer Host or framing. *)

val meth : 'body t -> Method.t
val target : 'body t -> Target.t
val version : 'body t -> Version.t
val headers : 'body t -> Headers.t
val body : 'body t -> 'body
val with_headers : Headers.t -> 'body t -> 'body t
val with_body : 'b -> 'a t -> 'b t

val map_body : ('a -> 'b) -> 'a t -> 'b t
(** Calls the function exactly once; exceptions and effects belong to the
    caller. Core does not copy, consume, close, or schedule the body. *)
