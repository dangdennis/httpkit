module O = Httpkit.Observation
module A = Httpkit_transport_eio

type t = {
  sink : O.sink;
  now : unit -> float;
  mutable next : int64;
  mutable active : int;
  capacity : int;
  mutable draining : bool;
}

let create ?observe ~capacity ~now () =
  Option.map
    (fun sink ->
      { sink; now; next = 0L; active = 0; capacity; draining = false })
    observe

let emit t event =
  try t.sink event with Eio.Cancel.Cancelled _ as exn -> raise exn | _ -> ()

let progress t =
  if t.draining then
    emit t (O.Shutdown_progress { active_connections = t.active })

let add counter count length =
  if count > 0 && count <= length then
    let n = Int64.of_int count in
    counter := Int64.add !counter (min n (Int64.sub Int64.max_int !counter))

type scope = {
  owner : t;
  connection : int64;
  request : int64;
  failure_reported : bool ref;
}

let measure t =
  let started = t.now () in
  fun () ->
    try
      let duration = t.now () -. started in
      if Float.is_finite duration && duration >= 0. then Some duration else None
    with _ -> None

let phase = function
  | A.Timeout.Head -> O.Header
  | Body -> O.Body
  | Write -> O.Write
  | Idle -> O.Idle
  | Shutdown -> O.Shutdown

let rec classify = function
  | Eio.Cancel.Cancelled _ -> O.Cancelled
  | Eio.Time.Timeout -> O.Timeout O.Application
  | Eio.Exn.Multiple errors -> (
      match List.map (fun (exn, _) -> classify exn) errors with
      | first :: rest when List.for_all (( = ) first) rest -> first
      | _ -> O.Mixed_failure)
  | A.Error (A.Timeout p) -> O.Timeout (phase p)
  | A.Error (A.Engine A.Engine.Resource_limit) -> O.Resource_limit
  | A.Error (A.Engine (A.Engine.Protocol _)) -> O.Protocol_error
  | A.Error (A.Engine A.Engine.Cancelled) -> O.Cancelled
  | End_of_file | A.Error (A.Transport End_of_file) -> O.Client_disconnected
  | A.Error (A.Transport _) -> O.Transport_error
  | _ -> O.Application_error

let response scope status =
  Option.iter
    (fun s ->
      emit s.owner
        (O.Response_headers_enqueued
           { connection = s.connection; request = s.request; status }))
    scope

let body_limit scope limit =
  Option.iter
    (fun s ->
      emit s.owner
        (O.Body_limit_rejected
           { connection = s.connection; request = s.request; limit }))
    scope

let connection_failed scope exn =
  Option.iter
    (fun s ->
      if not !(s.failure_reported) then (
        s.failure_reported := true;
        emit s.owner
          (O.Connection_failed
             { connection = s.connection; failure = classify exn })))
    scope

let callback scope stage f =
  match scope with
  | None -> f ()
  | Some s -> (
      let duration = measure s.owner in
      let finish failure =
        emit s.owner
          (O.Callback_finished
             {
               connection = s.connection;
               request = s.request;
               stage;
               duration_seconds = duration ();
               failure;
             })
      in
      match f () with
      | value ->
          finish None;
          value
      | exception exn ->
          let trace = Printexc.get_raw_backtrace () in
          finish (Some (classify exn));
          Printexc.raise_with_backtrace exn trace)

let request scope id f =
  match scope with
  | None -> f None
  | Some s ->
      let s = { s with request = id } in
      let duration = measure s.owner in
      let outcome = ref (O.Failed O.Cancelled) in
      Fun.protect
        ~finally:(fun () ->
          emit s.owner
            (O.Request_finished
               {
                 connection = s.connection;
                 request = id;
                 duration_seconds = duration ();
                 outcome = !outcome;
               }))
        (fun () ->
          emit s.owner
            (O.Request_started { connection = s.connection; request = id });
          match f (Some s) with
          | value ->
              (outcome :=
                 match value with
                 | None -> O.Response_enqueued
                 | Some _ -> O.Upgraded);
              value
          | exception exn ->
              let trace = Printexc.get_raw_backtrace () in
              outcome := O.Failed (classify exn);
              Printexc.raise_with_backtrace exn trace)

let connection observation (transport : A.transport) f =
  match observation with
  | None -> f transport None
  | Some t ->
      let connection = t.next in
      t.next <- Int64.succ t.next;
      let start = ref None in
      let elapsed () =
        try
          Option.bind !start (fun start ->
              let seconds = t.now () -. start in
              if Float.is_finite seconds && seconds >= 0. then Some seconds
              else None)
        with _ -> None
      in
      let bytes_read = ref 0L and bytes_written = ref 0L in
      let close_status = ref O.Close_not_attempted in
      let close () =
        close_status := O.Close_failed;
        transport.close ();
        close_status := O.Closed
      in
      let wrapped : A.transport =
        {
          read =
            (fun bytes off length ->
              let count = transport.read bytes off length in
              add bytes_read count length;
              count);
          write =
            (fun bytes off length ->
              let count = transport.write bytes off length in
              add bytes_written count length;
              count);
          close;
        }
      in
      t.active <- t.active + 1;
      Fun.protect
        ~finally:(fun () ->
          Fun.protect
            ~finally:(fun () ->
              t.active <- t.active - 1;
              Fun.protect
                ~finally:(fun () -> progress t)
                (fun () ->
                  emit t
                    (O.Connection_closed
                       {
                         connection;
                         active_connections = t.active;
                         duration_seconds = elapsed ();
                         bytes_read = !bytes_read;
                         bytes_written = !bytes_written;
                         close_status = !close_status;
                       })))
            (fun () ->
              if !close_status = O.Close_not_attempted then
                Eio.Cancel.protect close))
        (fun () ->
          start := Some (t.now ());
          emit t
            (O.Connection_accepted { connection; active_connections = t.active });
          if t.active = t.capacity then
            emit t
              (O.Admission_saturated
                 { active_connections = t.active; capacity = t.capacity });
          progress t;
          f wrapped
            (Some
               {
                 owner = t;
                 connection;
                 request = 0L;
                 failure_reported = ref false;
               }))

let shutdown = function
  | None -> ()
  | Some t ->
      t.draining <- true;
      emit t (O.Shutdown_started { active_connections = t.active });
      progress t

let shutdown_finished = function
  | Some t when t.draining && t.active = 0 -> emit t O.Shutdown_finished
  | _ -> ()
