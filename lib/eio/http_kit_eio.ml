open Http_kit_core
module Engine = Http_kit_engine
module Timeout = Engine.Timeout

type transport = {
  read : bytes -> int -> int -> int;
  write : string -> int -> int -> int;
  close : unit -> unit;
}

let of_flow flow =
  let scratch = Cstruct.create 16384 in
  {
    read =
      (fun bytes off len ->
        try
          let n =
            Eio.Flow.single_read flow (Cstruct.sub scratch 0 (min len 16384))
          in
          Cstruct.blit_to_bytes scratch 0 bytes off n;
          n
        with End_of_file -> 0);
    write =
      (fun bytes off len ->
        Eio.Flow.single_write flow
          [ Cstruct.of_string ~off ~len:(min len 16384) bytes ]);
    close = (fun () -> Eio.Flow.close flow);
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
  now : unit -> float;
  sleep : float -> unit;
  changed : Eio.Condition.t;
  mutable input : string;
  mutable offset : int;
  mutable ready_handoff : bool;
  mutable claimed : bool;
  mutable ended : bool;
  mutable failure : failure option;
}

let signal c = Eio.Condition.broadcast c.changed

(* Record a failure before waking waiters. Otherwise an aborted queue becoming
   empty can let a concurrent flush report success before the I/O error wins. *)
let remember c failure =
  if c.failure = None then c.failure <- Some failure;
  Engine.abort c.engine Engine.Cancelled;
  signal c

let check_failure c =
  match c.failure with None -> () | Some failure -> raise (Error failure)

let checked = function Ok x -> x | Error e -> raise (Error (Engine e))

let timed c phase seconds f =
  match seconds with
  | None -> f ()
  | Some remaining ->
      if remaining <= 0. then (
        remember c (Timeout phase);
        raise (Error (Timeout phase)))
      else
        Eio.Fiber.first f (fun () ->
            c.sleep remaining;
            remember c (Timeout phase);
            raise (Error (Timeout phase)))

let rec wait c predicate =
  check_failure c;
  if not (predicate ()) then (
    Eio.Condition.await_no_mutex c.changed;
    wait c predicate)

let rec command c f =
  check_failure c;
  match checked (f ()) with
  | Engine.Accepted x ->
      signal c;
      x
  | Engine.Backpressured ->
      Eio.Condition.await_no_mutex c.changed;
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
        event
    | None when c.ended -> raise (Error (Engine Engine.Invalid_command))
    | None ->
        Eio.Condition.await_no_mutex c.changed;
        loop ()
  in
  loop ()

let submit_request c r = command c (fun () -> Engine.submit_request c.engine r)
let respond c id r = command c (fun () -> Engine.respond c.engine id r)

let send c id bytes =
  let size = Engine.max_send_size c.engine in
  if size = 0 && bytes <> "" then raise (Error (Engine Engine.Resource_limit));
  let rec loop off =
    if off < String.length bytes then (
      let n = min size (String.length bytes - off) in
      let chunk = String.sub bytes off n in
      command c (fun () -> Engine.send_data c.engine id chunk);
      loop (off + n))
  in
  loop 0

let finish ?trailers c id =
  command c (fun () -> Engine.finish ?trailers c.engine id)

let discard_body c id =
  ignore (checked (Engine.discard_body c.engine id));
  signal c

let continue_request c id =
  ignore (checked (Engine.continue_request c.engine id));
  signal c

let flush c =
  wait c (fun () -> Engine.queued_output_bytes c.engine = 0);
  check_failure c

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
    let state = Engine.input_state c.engine in
    let phase =
      match state with
      | `Idle -> Some Timeout.Idle
      | `Head -> Some Timeout.Head
      | `Body -> Some Timeout.Body
      | _ -> None
    in
    timer := Timeout.observe c.policy ~now:(c.now ()) ~phase !timer;
    match phase with
    | None ->
        Eio.Condition.await_no_mutex c.changed;
        loop ()
    | Some phase ->
        let left = Timeout.remaining ~now:(c.now ()) !timer in
        if Option.fold ~none:false ~some:(fun n -> n <= 0.) left then (
          remember c (Timeout phase);
          raise (Error (Timeout phase)));
        if c.offset < String.length c.input then (
          let n =
            checked
              (Engine.offer c.engine c.input ~off:c.offset
                 ~len:(String.length c.input - c.offset))
          in
          c.offset <- c.offset + n;
          if n > 0 then
            timer := Timeout.progress c.policy ~now:(c.now ()) !timer;
          signal c;
          Eio.Fiber.yield ();
          loop ())
        else
          let n =
            timed c phase left (fun () ->
                c.transport.read buffer 0 (Bytes.length buffer))
          in
          if n < 0 || n > Bytes.length buffer then
            raise (Error (Transport (Invalid_argument "transport read count")));
          if n = 0 then (
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
    match Engine.output c.engine with
    | None ->
        Eio.Condition.await_no_mutex c.changed;
        loop ()
    | Some (bytes, off, len) ->
        let len = min len 16384 in
        let n =
          timed c Timeout.Write (Timeout.duration c.policy Timeout.Write)
            (fun () -> c.transport.write bytes off len)
        in
        if n <= 0 || n > len then
          raise (Error (Transport (Invalid_argument "transport write count")));
        ignore (checked (Engine.acknowledge c.engine n));
        signal c;
        loop ()
  in
  loop ()

let with_connection ?(policy = Timeout.default) ~clock transport engine f =
  let c =
    {
      engine;
      transport;
      policy;
      now =
        (fun () ->
          Int64.to_float (Mtime.to_uint64_ns (Eio.Time.Mono.now clock)) /. 1e9);
      sleep = Eio.Time.Mono.sleep clock;
      changed = Eio.Condition.create ();
      input = "";
      offset = 0;
      ready_handoff = false;
      claimed = false;
      ended = false;
      failure = None;
    }
  in
  let guard f =
    try f () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Error failure as exn ->
        remember c failure;
        raise exn
    | exn ->
        remember c (Transport exn);
        raise (Error (Transport exn))
  in
  let result =
    try
      Ok
        (Eio.Fiber.first
           (fun () ->
             let result = f c in
             flush c;
             result)
           (fun () ->
             guard (fun () ->
                 Eio.Fiber.both (fun () -> read_loop c) (fun () -> write_loop c));
             Eio.Fiber.await_cancel ()))
    with
    | Eio.Exn.Multiple errors as exn ->
        (* Reader failure and a woken waiter can report the same stored failure.
           Collapse only adapter failures; preserve unrelated handler failures. *)
        if
          List.for_all
            (fun (exn, _) -> match exn with Error _ -> true | _ -> false)
            errors
        then
          match c.failure with
          | Some failure -> Error (Error failure)
          | None -> Error exn
        else Error exn
    | exn -> Error exn
  in
  let cleanup =
    if Result.is_ok result && c.claimed then Ok ()
    else (
      Engine.abort engine Engine.Cancelled;
      try
        Eio.Cancel.protect transport.close;
        Ok ()
      with exn -> Error exn)
  in
  match (result, cleanup) with
  | Error exn, _ -> raise exn
  | Ok _, Error exn -> raise (Error (Transport exn))
  | Ok value, Ok () -> value

let collect_body ?(limit = 1048576) c id =
  if limit < 0 then invalid_arg "negative body collection limit";
  let body = Buffer.create (min limit 4096) in
  let rec loop trailers =
    match next_event c with
    | Engine.Data (owner, data) when Engine.equal_id owner id ->
        if String.length data > limit - Buffer.length body then (
          remember c (Engine Engine.Resource_limit);
          raise (Error (Engine Engine.Resource_limit)));
        Buffer.add_string body data;
        loop trailers
    | Engine.Trailers (owner, trailers) when Engine.equal_id owner id ->
        loop trailers
    | Engine.Complete owner when Engine.equal_id owner id ->
        (Buffer.contents body, trailers)
    | _ ->
        remember c (Engine Engine.Invalid_command);
        raise (Error (Engine Engine.Invalid_command))
  in
  loop Headers.empty

let serve_connections ?limits ?output_limit ?informational_limit
    ?(max_connections = 1024) ?policy ~clock ~accept ~on_error handler =
  if max_connections <= 0 then invalid_arg "nonpositive connection limit";
  let create_engine () =
    checked (Engine.server ?limits ?output_limit ?informational_limit ())
  in
  (* Reject invalid immutable settings before accepting a transport. Each worker
     still creates its own engine and therefore its own ID/queue ownership. *)
  ignore (create_engine ());
  (* Fixed workers bound accepted transports, including handlers blocked on user
     work. Listener/backlog ownership stays with the caller. Accept failures
     stop the scope; connection failures are reported only after cleanup. *)
  let rec worker () =
    let transport = accept () in
    (try
       with_connection ?policy ~clock transport (create_engine ()) handler
     with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> on_error exn);
    Eio.Fiber.yield ();
    worker ()
  in
  Eio.Fiber.all (List.init max_connections (fun _ -> worker))
