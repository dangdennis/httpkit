open Http_kit_core
(** Native Lwt driver. All operations belong to one Lwt event loop. Reader and
    writer promises are cancelled and joined before scoped cleanup completes. *)

module Engine = Http_kit_engine
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

val monotonic_clock : clock

type failure =
  | Engine of Engine.error
  | Transport of exn
  | Timeout of Timeout.phase

exception Error of failure

type connection

val with_connection :
  ?policy:Timeout.policy ->
  ?clock:clock ->
  transport ->
  Engine.t ->
  (connection -> 'a Lwt.t) ->
  'a Lwt.t
(** Flushes accepted output on normal callback completion. Exceptions and
    cancellation abort and close. A successfully claimed handoff transfers close
    ownership. Clock injection supports deterministic deadline tests. *)

val next_event : connection -> Engine.event Lwt.t
val submit_request : connection -> 'a Request.t -> Engine.id Lwt.t
val respond : connection -> Engine.id -> 'a Response.t -> unit Lwt.t
val send : connection -> Engine.id -> string -> unit Lwt.t
val finish : ?trailers:Headers.t -> connection -> Engine.id -> unit Lwt.t
val discard_body : connection -> Engine.id -> unit Lwt.t
val continue_request : connection -> Engine.id -> unit Lwt.t
val flush : connection -> unit Lwt.t
val shutdown : connection -> unit Lwt.t

val take_handoff : connection -> transport * string
(** Valid once after receiving Handoff; includes the unconsumed input suffix.
    Ownership transfers on successful with_connection return. *)

val collect_body :
  ?limit:int -> connection -> Engine.id -> (string * Headers.t) Lwt.t
(** Consume one incoming body and trailers, at most 1 MiB by default. Excess
    aborts before appending. One promise chain owns event consumption. *)

val serve_connections :
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
