(** Runtime-neutral application observations. Events contain no addresses,
    targets, headers, cookies, bodies or exception text. *)

type close_status = Closed | Close_failed | Close_not_attempted

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

type sink = event -> unit
(** Sinks run synchronously on the application's domain/event loop. Keep them
    bounded and nonblocking; do not yield, mutate the server, or start detached
    work. Adapters isolate ordinary sink exceptions, while preserving runtime
    cancellation. No asynchronous queue or vendor integration is installed.
    Observations are best effort and must not be used for resource ownership or
    billing. A cancelled/failed sink may miss events. *)
