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
type request_outcome = Response_enqueued | Upgraded | Failed of failure

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
