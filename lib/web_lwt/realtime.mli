exception Protocol_error of string

val sse : ((string -> unit Lwt.t) -> unit Lwt.t) -> App.response

val websocket :
  ?max_frame:int ->
  ?max_message:int ->
  clock:Httpkit_transport_lwt.clock ->
  ?idle_timeout:float ->
  Httpkit_transport_lwt.transport ->
  string ->
  (Httpkit.Websocket.event -> Httpkit.Websocket.event option Lwt.t) ->
  unit Lwt.t
(** Bounded server loop with ping/pong, close handshake and cancellation. The
    enclosing application owns transport closure. Deadlines join cancelled
    callback and I/O work before returning; cleanup must eventually finish.
    Protect cleanup that must survive cancellation with [Lwt.no_cancel]. After
    sending Close, reads and writes share one absolute [idle_timeout] budget for
    the peer's reply; ping/pong cannot extend it. *)
