type outcome = Exited of int | Signaled of int | Timed_out

let now () = Mtime.Span.to_float_ns (Mtime_clock.elapsed ()) /. 1e9

let rec waitpid flags pid =
  try Unix.waitpid flags pid
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid flags pid

let run ~seconds f =
  if seconds <= 0. || not (Float.is_finite seconds) then
    invalid_arg "invalid watchdog duration";
  flush_all ();
  match Unix.fork () with
  | 0 -> (
      try
        f ();
        Coverage_hook.flush ();
        Unix._exit 0
      with _ ->
        Coverage_hook.flush ();
        Unix._exit 1)
  | pid ->
      let deadline = now () +. seconds in
      let rec wait () =
        match waitpid [ Unix.WNOHANG ] pid with
        | 0, _ ->
            if now () >= deadline then (
              (try Unix.kill pid Sys.sigkill
               with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
              ignore (waitpid [] pid);
              Timed_out)
            else (
              (try
                 ignore
                   (Unix.select [] [] []
                      (min 0.01 (max 0. (deadline -. now ()))))
               with Unix.Unix_error (Unix.EINTR, _, _) -> ());
              wait ())
        | _, Unix.WEXITED n -> Exited n
        | _, Unix.WSIGNALED n -> Signaled n
        | _, Unix.WSTOPPED _ -> wait ()
      in
      wait ()
