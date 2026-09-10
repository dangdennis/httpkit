(** Immutable response metadata. Status-specific body/framing rules belong to a
    codec. *)

type 'body t

val create :
  ?version:Version.t ->
  ?headers:Headers.t ->
  status:Status.t ->
  'body ->
  'body t
(** Defaults to HTTP/1.1 and empty headers. No reason phrase or framing is
    inferred. *)

val status : 'body t -> Status.t
val version : 'body t -> Version.t
val headers : 'body t -> Headers.t
val body : 'body t -> 'body
val with_headers : Headers.t -> 'body t -> 'body t
val with_body : 'b -> 'a t -> 'b t

val map_body : ('a -> 'b) -> 'a t -> 'b t
(** Calls the function exactly once; does not consume or close a body. *)
