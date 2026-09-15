open Httpkit_core
open Lwt.Syntax
module Engine = Httpkit_engine
module Timeout = Engine.Timeout

type transport = {
  read : bytes -> int -> int -> int Lwt.t;
  write : string -> int -> int -> int Lwt.t;
  close : unit -> unit Lwt.t;
}

let of_fd fd =
  {
    read = Lwt_unix.read fd;
    write = Lwt_unix.write_string fd;
    close = (fun () -> Lwt_unix.close fd);
  }

type clock = { now : unit -> float; sleep : float -> unit Lwt.t }

let monotonic_clock =
  {
    now =
      (fun () ->
        Int64.to_float (Mtime.to_uint64_ns (Mtime_clock.now ())) /. 1e9);
    sleep = Lwt_unix.sleep;
  }

type failure =
  | Engine of Engine.error
  | Transport of exn
  | Timeout of Timeout.phase

exception Error of failure

let failure_to_string = function
  | Engine error -> "engine: " ^ Engine.error_to_string error
  | Transport exn -> "transport: " ^ Printexc.to_string exn
  | Timeout phase ->
      let name =
        match phase with
        | Timeout.Idle -> "idle"
        | Head -> "head"
        | Body -> "body"
        | Write -> "write"
        | Shutdown -> "shutdown"
      in
      name ^ " timeout"

type connection = {
  engine : Engine.t;
  transport : transport;
  policy : Timeout.policy;
  clock : clock;
  changed : unit Lwt_condition.t;
  mutable input : string;
  mutable offset : int;
  mutable ready_handoff : bool;
  mutable claimed : bool;
  mutable ended : bool;
  mutable failure : failure option;
  mutable stopping : bool;
  on_output_queue : (int -> unit) option;
  mutable observed_output : int;
}

let broadcast c = Lwt_condition.broadcast c.changed ()

let signal c =
  (match c.on_output_queue with
  | None -> ()
  | Some observe ->
      let queued = Engine.queued_output_bytes c.engine in
      if queued <> c.observed_output then (
        c.observed_output <- queued;
        try observe queued with Lwt.Canceled as exn -> raise exn | _ -> ()));
  broadcast c

(* Record a failure before waking waiters. Otherwise an aborted queue becoming
   empty can let a concurrent flush report success before the I/O error wins. *)
let remember c failure =
  if c.failure = None then c.failure <- Some failure;
  Engine.abort c.engine Engine.Cancelled;
  broadcast c

let check_failure c =
  match c.failure with None -> () | Some failure -> raise (Error failure)

let checked = function Ok x -> x | Error e -> raise (Error (Engine e))

let timed c phase seconds f =
  match seconds with
  | None -> f ()
  | Some remaining when remaining <= 0. ->
      remember c (Timeout phase);
      Lwt.fail (Error (Timeout phase))
  | Some remaining ->
      Lwt.pick
        [
          f ();
          (let* () = c.clock.sleep remaining in
           remember c (Timeout phase);
           Lwt.fail (Error (Timeout phase)));
        ]

let rec wait c predicate =
  check_failure c;
  if predicate () then Lwt.return_unit
  else
    let* () = Lwt_condition.wait c.changed in
    wait c predicate

let rec command c f =
  check_failure c;
  match checked (f ()) with
  | Engine.Accepted x ->
      signal c;
      Lwt.return x
  | Engine.Backpressured ->
      let* () = Lwt_condition.wait c.changed in
      command c f

let next_event c =
  let rec loop () =
    check_failure c;
    match Engine.poll_event c.engine with
    | Some event ->
        (match event with
        | Engine.Handoff _ ->
            c.ready_handoff <- true;
            c.ended <- true
        | Engine.Closed _ -> c.ended <- true
        | _ -> ());
        signal c;
        Lwt.return event
    | None when c.ended -> Lwt.fail (Error (Engine Engine.Invalid_command))
    | None ->
        let* () = Lwt_condition.wait c.changed in
        loop ()
  in
  loop ()

let submit_request c r = command c (fun () -> Engine.submit_request c.engine r)
let respond c id r = command c (fun () -> Engine.respond c.engine id r)

let send c id bytes =
  let size = Engine.max_send_size c.engine in
  if size = 0 && bytes <> "" then
    Lwt.fail (Error (Engine Engine.Resource_limit))
  else
    let rec loop off =
      if off = String.length bytes then Lwt.return_unit
      else
        let n = min size (String.length bytes - off) in
        let chunk = String.sub bytes off n in
        let* () = command c (fun () -> Engine.send_data c.engine id chunk) in
        loop (off + n)
    in
    loop 0

let finish ?trailers c id =
  command c (fun () -> Engine.finish ?trailers c.engine id)

let discard_body c id =
  ignore (checked (Engine.discard_body c.engine id));
  signal c;
  Lwt.return_unit

let continue_request c id =
  ignore (checked (Engine.continue_request c.engine id));
  signal c;
  Lwt.return_unit

let flush c =
  let* () = wait c (fun () -> Engine.queued_output_bytes c.engine = 0) in
  check_failure c;
  Lwt.return_unit

let shutdown c =
  Engine.shutdown c.engine;
  signal c;
  timed c Timeout.Shutdown (Timeout.duration c.policy Timeout.Shutdown)
    (fun () -> wait c (fun () -> Engine.input_state c.engine = `Closed))

let take_handoff c =
  if (not c.ready_handoff) || c.claimed then
    raise (Error (Engine Engine.Invalid_command));
  c.claimed <- true;
  (c.transport, String.sub c.input c.offset (String.length c.input - c.offset))

let read_loop c =
  let buffer = Bytes.create 16384 and timer = ref Timeout.empty in
  let rec loop () =
    if c.stopping then Lwt.return_unit
    else
      let state = Engine.input_state c.engine in
      let phase =
        match state with
        | `Idle -> Some Timeout.Idle
        | `Head -> Some Timeout.Head
        | `Body -> Some Timeout.Body
        | _ -> None
      in
      timer := Timeout.observe c.policy ~now:(c.clock.now ()) ~phase !timer;
      match phase with
      | None ->
          let* () = Lwt_condition.wait c.changed in
          loop ()
      | Some phase ->
          let left = Timeout.remaining ~now:(c.clock.now ()) !timer in
          if Option.fold ~none:false ~some:(fun n -> n <= 0.) left then (
            remember c (Timeout phase);
            Lwt.fail (Error (Timeout phase)))
          else if c.offset < String.length c.input then (
            let n =
              checked
                (Engine.offer c.engine c.input ~off:c.offset
                   ~len:(String.length c.input - c.offset))
            in
            c.offset <- c.offset + n;
            if n > 0 then
              timer := Timeout.progress c.policy ~now:(c.clock.now ()) !timer;
            signal c;
            let* () = Lwt.pause () in
            loop ())
          else
            let* n =
              timed c phase left (fun () ->
                  c.transport.read buffer 0 (Bytes.length buffer))
            in
            if n < 0 || n > Bytes.length buffer then
              Lwt.fail
                (Error (Transport (Invalid_argument "transport read count")))
            else if n = 0 then (
              ignore (checked (Engine.input_eof c.engine));
              signal c;
              loop ())
            else (
              c.input <- Bytes.sub_string buffer 0 n;
              c.offset <- 0;
              loop ())
  in
  loop ()

let write_loop c =
  let rec loop () =
    if c.stopping then Lwt.return_unit
    else
      match Engine.output c.engine with
      | None ->
          let* () = Lwt_condition.wait c.changed in
          loop ()
      | Some (bytes, off, len) ->
          let len = min len 16384 in
          let* n =
            timed c Timeout.Write (Timeout.duration c.policy Timeout.Write)
              (fun () -> c.transport.write bytes off len)
          in
          if n <= 0 || n > len then
            Lwt.fail
              (Error (Transport (Invalid_argument "transport write count")))
          else (
            (* A closing response can cancel queued output while this write
               is suspended. Do not acknowledge the dropped queue when the
               already in-flight write completes. *)
            if Engine.queued_output_bytes c.engine > 0 then
              ignore (checked (Engine.acknowledge c.engine n));
            signal c;
            let* () = Lwt.pause () in
            loop ())
  in
  loop ()

let with_connection ?(policy = Timeout.default) ?on_output_queue
    ?(clock = monotonic_clock) transport engine f =
  let c =
    {
      engine;
      transport;
      policy;
      clock;
      changed = Lwt_condition.create ();
      input = "";
      offset = 0;
      ready_handoff = false;
      claimed = false;
      ended = false;
      failure = None;
      stopping = false;
      on_output_queue;
      observed_output = -1;
    }
  in
  let guard f =
    Lwt.catch f (function
      | Lwt.Canceled as exn -> Lwt.fail exn
      | Error failure as exn ->
          remember c failure;
          Lwt.fail exn
      | exn ->
          remember c (Transport exn);
          Lwt.fail (Error (Transport exn)))
  in
  let reader = guard (fun () -> read_loop c)
  and writer = guard (fun () -> write_loop c) in
  let work =
    Lwt.catch
      (fun () ->
        let* result = f c in
        let* () = flush c in
        Lwt.return result)
      Lwt.fail
  in
  let succeeded = ref false in
  Lwt.finalize
    (fun () ->
      let* result =
        Lwt.pick
          [
            work;
            (let* () = Lwt.pick [ reader; writer ] in
             fst (Lwt.task ()));
          ]
      in
      succeeded := true;
      Lwt.return result)
    (fun () ->
      (* A ready promise may already be delivering its callback when cancellation
         runs. The stop flag prevents that callback from opening another wait. *)
      c.stopping <- true;
      broadcast c;
      Lwt.cancel reader;
      Lwt.cancel writer;
      Lwt.cancel work;
      (* Cancelling work starts its finalizers but does not join them. They may
         still own resources needed by the callback, including the transport.
         Preserve the winning failure while waiting for all owned work. *)
      let settle promise =
        Lwt.catch
          (fun () ->
            let* _ = promise in
            Lwt.return_unit)
          (fun _ -> Lwt.return_unit)
      in
      let* () = Lwt.join [ settle reader; settle writer; settle work ] in
      if !succeeded && c.claimed then Lwt.return_unit
      else (
        Engine.abort engine Engine.Cancelled;
        Lwt.catch transport.close (fun exn ->
            if !succeeded then Lwt.fail (Error (Transport exn))
            else Lwt.return_unit)))

let collect_body ?(limit = 1048576) c id =
  if limit < 0 then invalid_arg "negative body collection limit";
  let body = Buffer.create (min limit 4096) in
  let rec loop trailers =
    let* event = next_event c in
    match event with
    | Engine.Data (owner, data) when Engine.equal_id owner id ->
        if String.length data > limit - Buffer.length body then (
          remember c (Engine Engine.Resource_limit);
          Lwt.fail (Error (Engine Engine.Resource_limit)))
        else (
          Buffer.add_string body data;
          loop trailers)
    | Engine.Trailers (owner, trailers) when Engine.equal_id owner id ->
        loop trailers
    | Engine.Complete owner when Engine.equal_id owner id ->
        Lwt.return (Buffer.contents body, trailers)
    | _ ->
        remember c (Engine Engine.Invalid_command);
        Lwt.fail (Error (Engine Engine.Invalid_command))
  in
  loop Headers.empty

let serve_connections ?limits ?output_limit ?informational_limit
    ?(max_connections = 1024) ?policy ?clock ~accept ~on_error handler =
  if max_connections <= 0 then invalid_arg "nonpositive connection limit";
  let create_engine () =
    checked (Engine.server ?limits ?output_limit ?informational_limit ())
  in
  (* Reject invalid immutable settings before accepting a transport. Each worker
     still creates its own engine and therefore its own ID/queue ownership. *)
  ignore (create_engine ());
  let stopping = ref false in
  let rec worker () =
    if !stopping then Lwt.return_unit
    else
      let* transport = accept () in
      let* () =
        Lwt.catch
          (fun () ->
            with_connection ?policy ?clock transport (create_engine ()) handler)
          (function Lwt.Canceled as exn -> Lwt.fail exn | exn -> on_error exn)
      in
      let* () = Lwt.pause () in
      worker ()
  in
  (* pick fails promptly when any worker fails. finalize also joins siblings;
     bare Lwt.join would wait forever on workers still blocked in accept. *)
  let workers =
    List.init max_connections (fun _ -> Lwt.catch worker Lwt.fail)
  in
  Lwt.finalize
    (fun () -> Lwt.pick workers)
    (fun () ->
      stopping := true;
      List.iter Lwt.cancel workers;
      Lwt.join
        (List.map
           (fun p -> Lwt.catch (fun () -> p) (fun _ -> Lwt.return_unit))
           workers))
