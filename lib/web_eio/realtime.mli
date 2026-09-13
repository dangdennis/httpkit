exception Protocol_error of string

val sse : ((string -> unit) -> unit) -> App.response

val websocket :
  ?max_frame:int ->
  ?max_message:int ->
  clock:_ Eio.Time.Mono.t ->
  ?idle_timeout:float ->
  Httpkit_transport_eio.transport ->
  string ->
  (Httpkit.Websocket.event -> Httpkit.Websocket.event option) ->
  unit
(** Bounded server loop; replies to ping and completes close. One callback at a
    time. The enclosing application owns transport closure. *)
