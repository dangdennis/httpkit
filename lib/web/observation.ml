type close_status = Closed | Close_failed | Close_not_attempted

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
