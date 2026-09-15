open Httpkit_core

type request

val head : request -> unit Request.t
val params : request -> (string * string) list
val param : string -> request -> string option

val read : request -> string option
(** Single-reader stream; None is terminal. Reading lazily grants Expect:
    100-continue. *)

val body : ?limit:int -> request -> string
val json : ?limit:int -> request -> (Yojson.Safe.t, Httpkit.Json.error) result

val form :
  ?limit:int -> request -> ((string * string) list, Httpkit.Url.error) result

val multipart : request -> Httpkit.Multipart.t -> (unit, string) result
val request_id : request -> string
val peer : request -> string

type response
type handler = request -> response
type middleware = handler -> handler

val reply : string Response.t -> response

val stream :
  ?status:int ->
  ?headers:(string * string) list ->
  ((string -> unit) -> unit) ->
  response
(** Acquire producer resources inside the callback; it is skipped for HEAD. *)

val websocket :
  allowed_origins:string list ->
  request ->
  (Httpkit_transport_eio.transport -> string -> unit) ->
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
  ?observe:Httpkit.Observation.sink ->
  clock:_ Eio.Time.Mono.t ->
  random:(int -> string) ->
  stop:unit Eio.Promise.t ->
  accept:(unit -> Httpkit_transport_eio.transport * string) ->
  on_error:(exn -> unit) ->
  handler ->
  unit
(** Stops admission and drains active connections on [stop]. Callers own the
    listener. A transport returned by a late accept is closed under cancellation
    protection, and its close is joined before return; close must eventually
    finish. Application callback deadlines cover unrelated work as well as body
    processing. [policy] configures absolute header and graceful-shutdown
    deadlines and body/write/keep-alive idle deadlines; it defaults to
    [Httpkit_engine.Timeout.default]. The independent [request_timeout] bounds
    each application exchange, even when a transport idle deadline is disabled.
    Upgraded protocols use their own callback/I/O timeout policy. [observe]
    optionally receives synchronous connection-scope observations; see
    [Httpkit.Observation] for privacy, byte-count and sink behavior contracts.
*)
