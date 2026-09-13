type 'a t
(** Switch/domain-local session middleware. The store is process-local. *)

val create :
  ?capacity:int ->
  ttl:float ->
  clock:_ Eio.Time.Mono.t ->
  random:(int -> string) ->
  unit ->
  'a t

val login : 'a t -> 'a -> App.response -> App.response
val logout : 'a t -> App.request -> App.response -> App.response
val find : 'a t -> App.request -> 'a Httpkit.Session.session option
val rotate : 'a t -> App.request -> 'a -> App.response -> App.response

val require :
  'a t -> ('a Httpkit.Session.session -> App.handler) -> App.handler

val csrf : 'a t -> origins:string list -> App.middleware
(** Unsafe requests require a session, its CSRF token, and an allowlisted
    Origin. *)
