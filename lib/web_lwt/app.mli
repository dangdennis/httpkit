open Httpkit_core

type request

val head : request -> unit Request.t
val params : request -> (string * string) list
val param : string -> request -> string option

val read : request -> string option Lwt.t
(** Single-reader stream; None is terminal. Reading lazily grants Expect:
    100-continue. *)

val body : ?limit:int -> request -> string Lwt.t

val json :
  ?limit:int -> request -> (Yojson.Safe.t, Httpkit.Json.error) result Lwt.t

val form :
  ?limit:int ->
  request ->
  ((string * string) list, Httpkit.Url.error) result Lwt.t

val multipart : request -> Httpkit.Multipart.t -> (unit, string) result Lwt.t
val request_id : request -> string
val peer : request -> string

type response
type handler = request -> response Lwt.t
type middleware = handler -> handler

val reply : string Response.t -> response

val stream :
  ?status:int ->
  ?headers:(string * string) list ->
  ((string -> unit Lwt.t) -> unit Lwt.t) ->
  response
(** Acquire producer resources inside the callback; it is skipped for HEAD. *)

val websocket :
  allowed_origins:string list ->
  request ->
  (Httpkit_transport_lwt.transport -> string -> unit Lwt.t) ->
  response
(** Callback owns the upgraded transport for its scope; it is always closed on
    exit. *)

val map_headers : (Headers.t -> Headers.t) -> response -> response
val status : response -> int
val route : Method.t -> string -> handler -> handler Httpkit_router.route

val routes :
  ?middleware:middleware list -> handler Httpkit_router.route list -> handler
(** Explicit route order, GET fallback for HEAD, 404 and 405/Allow responses. *)

val serve :
  ?max_connections:int ->
  ?body_limit:int ->
  ?output_limit:int ->
  ?limits:Httpkit_engine.Codec.limits ->
  ?policy:Httpkit_engine.Timeout.policy ->
  ?request_timeout:float ->
  clock:Httpkit_transport_lwt.clock ->
  random:(int -> string) ->
  stop:unit Lwt.t ->
  accept:(unit -> (Httpkit_transport_lwt.transport * string) Lwt.t) ->
  on_error:(exn -> unit Lwt.t) ->
  handler ->
  unit Lwt.t
(** Stops admission and drains active connections on [stop]. Callers own the
    listener. Application callback deadlines cover unrelated work as well as
    body processing. A timeout or external cancellation joins owned handler and
    stream cleanup before the connection closes. Cleanup that must survive
    cancellation should use [Lwt.no_cancel]; it must eventually finish. [policy]
    configures absolute header and graceful-shutdown deadlines and
    body/write/keep-alive idle deadlines; the default is
    [Httpkit_engine.Timeout.default]. [request_timeout] independently bounds the
    application exchange. Upgraded protocols use their own timeout policy. *)
