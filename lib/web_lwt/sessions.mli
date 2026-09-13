type 'a t

val create :
  ?capacity:int ->
  ttl:float ->
  clock:Httpkit_transport_lwt.clock ->
  random:(int -> string) ->
  unit ->
  'a t

val find : 'a t -> App.request -> 'a Httpkit.Session.session option Lwt.t
val login : 'a t -> 'a -> App.response -> App.response Lwt.t
val logout : 'a t -> App.request -> App.response -> App.response Lwt.t
val rotate : 'a t -> App.request -> 'a -> App.response -> App.response Lwt.t
val require : 'a t -> ('a Httpkit.Session.session -> App.handler) -> App.handler
val csrf : 'a t -> origins:string list -> App.middleware
