(** Runtime-neutral application observations. Events contain no addresses,
    targets, headers, cookies, bodies or exception text. *)

type close_status = Closed | Close_failed | Close_not_attempted
type timeout_phase = Header | Body | Write | Idle | Shutdown | Application

type failure =
  | Cancelled
  | Timeout of timeout_phase
  | Resource_limit
  | Protocol_error
  | Transport_error
  | Client_disconnected
  | Application_error
  | Mixed_failure

type callback_stage = Handler | Response_stream

type request_outcome =
  | Response_enqueued
  | Upgraded
  | Failed of failure
      (** [Response_enqueued] means application response production/framing and
          the discard command completed; it does not mean output drained or the
          peer read it. [Upgraded] ends the HTTP request scope at handoff,
          before the upgraded callback runs. [Failed] describes the exception
          leaving that scope after deadline/cancellation cleanup has joined. *)

(** Connection identifiers are local to one [serve] invocation. Active counts
    include accepted transports through their worker scope, including upgrades,
    callback cleanup, close and error reporting. [Connection_closed] means that
    scope has finished; [close_status] distinguishes successful close from a
    failed or unattempted close operation. Duration includes cleanup and error
    reporting and is [None] if a valid monotonic measurement is unavailable.
    Byte counts sum valid successful transport I/O return counts and saturate at
    [Int64.max_int]; they include protocol framing and upgraded traffic. They do
    not establish peer receipt or request-level delivery. [Shutdown_started]
    denotes the explicit graceful-stop signal, not external cancellation. *)
type event =
  | Connection_accepted of { connection : int64; active_connections : int }
  | Connection_closed of {
      connection : int64;
      active_connections : int;
      duration_seconds : float option;
      bytes_read : int64;
      bytes_written : int64;
      close_status : close_status;
    }
  | Shutdown_started of { active_connections : int }
  | Admission_saturated of { active_connections : int; capacity : int }
      (** All configured application worker slots are occupied. No connection
          rejection or external backlog size is implied. *)
  | Shutdown_progress of { active_connections : int }
      (** Snapshot after graceful-stop observation and subsequent scope changes.
          Late accepts can increase the count; zero alone does not mean
          finished. *)
  | Shutdown_finished
      (** Explicit graceful stop was observed and all worker scopes joined.
          Close errors remain visible separately; this does not prove every
          user-supplied close operation succeeded. *)
  | Body_limit_rejected of { connection : int64; request : int64; limit : int }
      (** Application read or collection quota, in bytes. Does not identify
          codec, multipart or other quotas, or promise an HTTP 413 response. *)
  | Output_queue_changed of { connection : int64; queued_bytes : int }
      (** Serialized engine output after normal queue changes. Aborts/teardown
          bypass queue hooks; remove the connection's gauge on
          [Connection_closed]. Does not measure total memory, socket buffering
          or peer receipt. *)
  | Connection_failed of { connection : int64; failure : failure }
  | Request_started of { connection : int64; request : int64 }
  | Callback_finished of {
      connection : int64;
      request : int64;
      stage : callback_stage;
      duration_seconds : float option;
      failure : failure option;
    }
  | Response_headers_enqueued of {
      connection : int64;
      request : int64;
      status : int;
    }
  | Request_finished of {
      connection : int64;
      request : int64;
      duration_seconds : float option;
      outcome : request_outcome;
    }

type sink = event -> unit
(** Request identifiers are engine exchange numbers local to the connection.
    [Request_started] follows a validated request head. [Callback_finished]
    measures handler or stream callback lifetime, including its finalizers but
    excluding error recovery. A recovered handler error can be followed by an
    enqueued 500 and a successful request scope. HEAD skips stream callbacks.
    [Response_headers_enqueued] reports an accepted final response head, not
    wire delivery; informational responses are excluded. [Connection_failed]
    reports the first error passed to connection/shutdown error handling; header
    and idle timeouts may occur before any request exists. Timeout-driven
    callback cancellation can be reported as [Cancelled], while its enclosing
    request ends with [Timeout Application]. Error categories contain no
    exception text and [Resource_limit] does not identify a particular quota.

    Sinks run synchronously on the application's domain/event loop. Keep them
    bounded and nonblocking; do not yield, mutate the server, or start detached
    work. Adapters isolate ordinary sink exceptions, while preserving runtime
    cancellation. No asynchronous queue or vendor integration is installed.
    Observations are best effort and must not be used for resource ownership or
    billing. A cancelled/failed sink may miss events. *)
