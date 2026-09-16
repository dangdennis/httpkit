open Httpkit_core
(** Native Lwt driver from [httpkit-transport-lwt]. The application API is
    [Httpkit_lwt] in [httpkit-lwt]. All operations belong to one Lwt event loop.
    Reader and writer promises are cancelled and joined before scoped cleanup
    completes. *)

module Engine = Httpkit_engine
module Timeout = Engine.Timeout

type transport = {
  read : bytes -> int -> int -> int Lwt.t;
  write : string -> int -> int -> int Lwt.t;
  close : unit -> unit Lwt.t;
}
(** Reads return zero at EOF; writes return a positive consumed prefix. Pending
    operations must support Lwt cancellation. The driver takes close ownership.
*)

val of_fd : Lwt_unix.file_descr -> transport

type clock = { now : unit -> float; sleep : float -> unit Lwt.t }
(** Monotonic time and cancellable delay. [sleep] must release its timer on
    cancellation; any asynchronous cleanup must eventually finish. *)

val monotonic_clock : clock

type failure =
  | Engine of Engine.error
  | Transport of exn
  | Timeout of Timeout.phase

exception Error of failure

val failure_to_string : failure -> string
(** Category and diagnostic detail. Transport exception text is supplied by the
    transport; callers control whether and where it is logged. *)

type connection

val with_connection :
  ?policy:Timeout.policy ->
  ?on_output_queue:(int -> unit) ->
  ?clock:clock ->
  transport ->
  Engine.t ->
  (connection -> 'a Lwt.t) ->
  'a Lwt.t
(** Flushes accepted output on normal callback completion. Exceptions and
    cancellation abort and close. A successfully claimed handoff transfers close
    ownership. Clock injection supports deterministic deadline tests.
    [on_output_queue] observes serialized queued bytes after normal engine state
    changes, suppressing duplicate values. The callback is synchronous: do not
    block, yield, or mutate the connection/engine. Ordinary exceptions are
    ignored; cancellation propagates. Failure/teardown bypass callbacks so they
    cannot interrupt cleanup; retire the gauge when the connection scope ends.
    The callback does not establish peer receipt or total buffer memory. *)

val next_event : connection -> Engine.event Lwt.t
(** Complete means incoming completion, not outgoing drain. *)

val submit_request : connection -> 'a Request.t -> Engine.id Lwt.t
val respond : connection -> Engine.id -> 'a Response.t -> unit Lwt.t
val send : connection -> Engine.id -> string -> unit Lwt.t

val finish : ?trailers:Headers.t -> connection -> Engine.id -> unit Lwt.t
(** Finalizes HTTP framing; invalid after handoff. Waits for client Expect
    permission. *)

val discard_body : connection -> Engine.id -> unit Lwt.t
(** Discard still validates framing; await incoming Complete before reuse. *)

val continue_request : connection -> Engine.id -> unit Lwt.t
(** Explicit client override of the Expect wait; receiving 100 also grants
    permission. *)

val flush : connection -> unit Lwt.t

val shutdown : connection -> unit Lwt.t
(** Wait for graceful closure under the configured deadline. The owner must
    complete an active exchange; expiry aborts the connection. *)

val take_handoff : connection -> transport * string
(** Valid once after receiving Handoff; includes the unconsumed input suffix.
    Ownership transfers on successful with_connection return. *)

val collect_body :
  ?limit:int -> connection -> Engine.id -> (string * Headers.t) Lwt.t
(** Consume one incoming body and trailers, at most 1 MiB by default. Excess
    aborts before appending. One promise chain owns event consumption. *)

val serve_connections :
  ?limits:Engine.Codec.limits ->
  ?output_limit:int ->
  ?informational_limit:int ->
  ?max_connections:int ->
  ?policy:Timeout.policy ->
  ?clock:clock ->
  accept:(unit -> transport Lwt.t) ->
  on_error:(exn -> unit Lwt.t) ->
  (connection -> unit Lwt.t) ->
  unit Lwt.t
(** Bounded native workers, default 1024. The caller owns listener/backlog.
    Connection errors are reported after cleanup; accept/on_error failure and
    cancellation stop and join every worker. No detached Lwt.async tasks. *)

val reusable : connection -> bool
(** Check idle client state including unconsumed transport staging. Call after
    Complete and flush; a stale peer may still fail the next request. *)
