open Lwt.Infix
module O = Httpkit.Observation
module A = Httpkit_transport_lwt

type t = {
  sink : O.sink;
  now : unit -> float;
  mutable next : int64;
  mutable active : int;
}

let create ?observe ~now () =
  Option.map (fun sink -> { sink; now; next = 0L; active = 0 }) observe

let emit t event =
  try t.sink event with Lwt.Canceled as exn -> raise exn | _ -> ()

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

let classify = function
  | Lwt.Canceled -> O.Cancelled
  | Lwt_unix.Timeout -> O.Timeout O.Application
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
  | Some s ->
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
      Lwt.try_bind f
        (fun value ->
          finish None;
          Lwt.return value)
        (fun exn ->
          finish (Some (classify exn));
          Lwt.fail exn)

let request scope id f =
  match scope with
  | None -> f None
  | Some s ->
      let s = { s with request = id } in
      let duration = measure s.owner in
      let outcome = ref (O.Failed O.Cancelled) in
      Lwt.finalize
        (fun () ->
          emit s.owner
            (O.Request_started { connection = s.connection; request = id });
          Lwt.try_bind
            (fun () -> f (Some s))
            (fun value ->
              (outcome :=
                 match value with
                 | None -> O.Response_enqueued
                 | Some _ -> O.Upgraded);
              Lwt.return value)
            (fun exn ->
              outcome := O.Failed (classify exn);
              Lwt.fail exn))
        (fun () ->
          emit s.owner
            (O.Request_finished
               {
                 connection = s.connection;
                 request = id;
                 duration_seconds = duration ();
                 outcome = !outcome;
               });
          Lwt.return_unit)

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
        transport.close () >|= fun () -> close_status := O.Closed
      in
      let wrapped : A.transport =
        {
          read =
            (fun bytes off length ->
              transport.read bytes off length >|= fun count ->
              add bytes_read count length;
              count);
          write =
            (fun bytes off length ->
              transport.write bytes off length >|= fun count ->
              add bytes_written count length;
              count);
          close;
        }
      in
      t.active <- t.active + 1;
      Lwt.finalize
        (fun () ->
          start := Some (t.now ());
          emit t
            (O.Connection_accepted { connection; active_connections = t.active });
          f wrapped
            (Some
               {
                 owner = t;
                 connection;
                 request = 0L;
                 failure_reported = ref false;
               }))
        (fun () ->
          Lwt.finalize
            (fun () ->
              if !close_status = O.Close_not_attempted then
                Lwt.no_cancel (Lwt.apply close ())
              else Lwt.return_unit)
            (fun () ->
              t.active <- t.active - 1;
              emit t
                (O.Connection_closed
                   {
                     connection;
                     active_connections = t.active;
                     duration_seconds = elapsed ();
                     bytes_read = !bytes_read;
                     bytes_written = !bytes_written;
                     close_status = !close_status;
                   });
              Lwt.return_unit))

let shutdown = function
  | None -> ()
  | Some t -> emit t (O.Shutdown_started { active_connections = t.active })
