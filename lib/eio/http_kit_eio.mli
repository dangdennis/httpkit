open Http_kit_core
(** Native Eio driver. All connection operations must run in the same domain.
    Reader/writer fibers are scoped to with_connection; no background work
    survives its return. There is no shared promise abstraction with Lwt. *)

module Engine = Http_kit_engine
module Timeout = Engine.Timeout

type transport = {
  read : bytes -> int -> int -> int;
  write : string -> int -> int -> int;
  close : unit -> unit;
}
(** Reads return zero at EOF; writes return a positive consumed prefix. These
    operations must honor Eio cancellation. The driver takes close ownership. *)

val of_flow : ([> Eio.Flow.two_way_ty | `Close ] as 'a) Eio.Std.r -> transport

type failure =
  | Engine of Engine.error
  | Transport of exn
  | Timeout of Timeout.phase

exception Error of failure

type connection

val with_connection :
  ?policy:Timeout.policy ->
  clock:_ Eio.Time.Mono.t ->
  transport ->
  Engine.t ->
  (connection -> 'a) ->
  'a
(** Runs the callback with concurrent bounded input/output. On normal return,
    flushes accepted output before cancellation/cleanup. Exceptions/cancellation
    abort and close. A successfully claimed handoff transfers close ownership.
*)

val next_event : connection -> Engine.event
val submit_request : connection -> 'a Request.t -> Engine.id
val respond : connection -> Engine.id -> 'a Response.t -> unit

val send : connection -> Engine.id -> string -> unit
(** Splits data into bounded chunks and waits natively for output capacity. *)

val finish : ?trailers:Headers.t -> connection -> Engine.id -> unit
val discard_body : connection -> Engine.id -> unit
val continue_request : connection -> Engine.id -> unit
val flush : connection -> unit

val shutdown : connection -> unit
(** Wait for graceful closure under the configured deadline. An active exchange
    must still be completed by its owner; expiry aborts the connection. *)

val take_handoff : connection -> transport * string
(** Valid once after receiving Handoff. Includes unconsumed staging bytes. On
    successful with_connection return the caller owns transport cleanup. *)

val collect_body : ?limit:int -> connection -> Engine.id -> string * Headers.t
(** Consume the current incoming body and trailers, at most 1 MiB by default.
    Exceeding the limit aborts the connection before appending excess bytes. One
    fiber owns event consumption; do not race this with next_event. *)

val serve_connections :
  ?max_connections:int ->
  ?policy:Timeout.policy ->
  clock:_ Eio.Time.Mono.t ->
  accept:(unit -> transport) ->
  on_error:(exn -> unit) ->
  (connection -> unit) ->
  unit
(** At most 1024 admitted connections by default. Owns connection scopes; the
    caller owns the listener and its backlog. Connection failures call on_error
    after cleanup. Accept/on_error failure cancels and joins all workers. *)
