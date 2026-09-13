open Common

type result = { status : Unix.process_status; stdout : string; stderr : string }
type child = { pid : int; mutable reaped : Unix.process_status option }

let children = ref []

let status_code = function
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n

let signal child signal =
  if child.reaped = None then
    try Unix.kill (-child.pid) signal
    with Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let poll child =
  match child.reaped with
  | Some s -> Some s
  | None ->
      let pid, s = Unix.waitpid [ Unix.WNOHANG ] child.pid in
      if pid = 0 then None
      else (
        child.reaped <- Some s;
        children := List.filter (fun c -> c != child) !children;
        Some s)

let rec wait child deadline =
  match poll child with
  | Some s -> s
  | None ->
      if monotonic () >= deadline then
        fail "Process %d exceeded its deadline" child.pid
      else (
        sleep 0.01;
        wait child deadline)

let stop child =
  if child.reaped = None then (
    signal child Sys.sigterm;
    (try ignore (wait child (monotonic () +. 1.))
     with Error _ ->
       signal child Sys.sigkill;
       let _, s = Unix.waitpid [] child.pid in
       child.reaped <- Some s);
    children := List.filter (fun c -> c != child) !children)

let () = at_exit (fun () -> List.iter stop !children)

let spawn ?(cwd = root) ?(env = environment ()) ?(stdin = Unix.stdin) ~stdout
    ~stderr args =
  require (args <> []) "Empty process command";
  match Unix.fork () with
  | 0 -> (
      try
        ignore (Unix.setsid ());
        Unix.chdir cwd;
        Unix.dup2 stdin Unix.stdin;
        Unix.dup2 stdout Unix.stdout;
        Unix.dup2 stderr Unix.stderr;
        Unix.execvpe (List.hd args) (Array.of_list args) (env_array env)
      with exn ->
        prerr_endline (Printexc.to_string exn);
        Unix._exit 127)
  | pid ->
      let child = { pid; reaped = None } in
      children := child :: !children;
      child

let run ?cwd ?env ?(timeout = 1800.) ?(check = true) args =
  with_temp "httpkit-process-" (fun dir ->
      let output = dir / "stdout" and error = dir / "stderr" in
      let out =
        Unix.openfile output [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
      and err =
        Unix.openfile error [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
      in
      let child =
        Fun.protect
          ~finally:(fun () ->
            Unix.close out;
            Unix.close err)
          (fun () -> spawn ?cwd ?env ~stdout:out ~stderr:err args)
      in
      let status =
        Fun.protect
          ~finally:(fun () -> stop child)
          (fun () -> wait child (monotonic () +. timeout))
      in
      let result = { status; stdout = read output; stderr = read error } in
      if check && status_code status <> 0 then
        fail "Command failed (%d): %s\n%s%s" (status_code status)
          (String.concat " " (List.map Filename.quote args))
          result.stdout result.stderr;
      result)

let output ?cwd ?env ?timeout args = (run ?cwd ?env ?timeout args).stdout

let call ?cwd ?env ?timeout args =
  let r = run ?cwd ?env ?timeout args in
  print_string r.stdout;
  prerr_string r.stderr;
  flush stdout

let with_child ?cwd ?env ?stdin ~log args f =
  mkdir (Filename.dirname log);
  let fd =
    Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  let child =
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () -> spawn ?cwd ?env ?stdin ~stdout:fd ~stderr:fd args)
  in
  Fun.protect ~finally:(fun () -> stop child) (fun () -> f child)
