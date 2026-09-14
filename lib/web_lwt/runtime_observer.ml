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

let connection observation (transport : A.transport) f =
  match observation with
  | None -> f transport
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
          f wrapped)
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
