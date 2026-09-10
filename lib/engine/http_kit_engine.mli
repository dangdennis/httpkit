open Http_kit_core
(** Single-owner sans-I/O HTTP/1 client/server connections. No callbacks or I/O.
    Admission is serial; pipelined bytes remain with the caller until the active
    exchange retires. An engine is not safe for simultaneous domain mutation. *)

module Codec = Http_kit_http1

type id

val id_number : id -> int64

val equal_id : id -> id -> bool
(** IDs are connection-owned. Equal numbers from different engines are distinct.
*)

type error =
  | Protocol of Codec.error
  | Invalid_command
  | Resource_limit
  | Cancelled

val error_to_string : error -> string

type 'a submission = Accepted of 'a | Backpressured

type event =
  | Request of id * unit Request.t
  | Response of id * unit Response.t
  | Informational of id * unit Response.t
  | Data of id * string
  | Trailers of id * Headers.t
  | Complete of id
  | Body_aborted of id
  | Handoff of id
  | Closed of error option

type t

val server :
  ?limits:Codec.limits ->
  ?output_limit:int ->
  ?informational_limit:int ->
  unit ->
  (t, error) result

val client :
  ?limits:Codec.limits ->
  ?output_limit:int ->
  ?informational_limit:int ->
  unit ->
  (t, error) result
(** Defaults: 65536 queued output bytes, 16 informational heads per exchange.
    Positive output limit and nonnegative informational limit are required. *)

val submit_request : t -> 'a Request.t -> (id submission, error) result

val respond : t -> id -> 'a Response.t -> (unit submission, error) result
(** Informational responses do not start an outgoing body. A final response
    before the request body finishes aborts that body and forces close. *)

val send_data : t -> id -> string -> (unit submission, error) result

val finish : ?trailers:Headers.t -> t -> id -> (unit submission, error) result
(** Backpressured commands have no effect and may be retried. Accepted commands
    must not be retried. Body/frame failures abort an already committed
    exchange. *)

val continue_request : t -> id -> (unit, error) result
(** Explicit client policy override for an Expect wait (e.g. an adapter
    deadline). A received 100 response also enables the body. No request is
    retried implicitly. *)

val discard_body : t -> id -> (unit, error) result
(** Consume future incoming body data without retaining Data events. Still
    checks framing, quotas and EOF; success requires a Complete event before
    safe reuse. *)

val offer : t -> string -> off:int -> len:int -> (int, error) result
(** Exact consumed prefix. Returns zero under event/admission backpressure.
    Accepted body chunks are owned copies; caller buffers may then be reused. *)

val poll_event : t -> event option
(** At most one queued event. Polling may advance an already-buffered End, but
    never performs a read. Complete refers to incoming body completion. *)

val output : t -> (string * int * int) option
(** Stable queued bytes and slice until acknowledgement; no copy on polling. *)

val acknowledge : t -> int -> (unit, error) result
(** Retire a prefix of the currently offered output slice only. Invalid counts
    have no effect. Handoff is emitted only after all HTTP output is
    acknowledged. *)

val input_eof : t -> (unit, error) result

val shutdown : t -> unit
(** Stop admission and close after the active exchange finishes. An adapter owns
    any graceful-shutdown deadline and calls abort if it expires. *)

val abort : t -> error -> unit
(** Idempotent; drops queued work and exposes one Closed event, preserving the
    first failure. Does nothing after ownership has transferred via Handoff. *)

val queued_output_bytes : t -> int

val queued_input_bytes : t -> int
(** Payload counters only. Metadata is separately bounded by codec limits;
    application-retained events are outside engine ownership. *)

val input_state : t -> [ `Idle | `Head | `Body | `Blocked | `Closed ]
(** Adapter readiness/deadline seam. Blocked means do not start a transport
    read. Idle means a server is waiting for the first byte of a new head. *)

val max_send_size : t -> int
(** Largest data chunk that can fit with framing, independent of currently
    queued output. Zero means this configuration cannot send body data. *)
