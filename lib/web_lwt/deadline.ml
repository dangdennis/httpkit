open Lwt.Infix

let settle promise =
  Lwt.catch (fun () -> promise >|= fun _ -> ()) (fun _ -> Lwt.return_unit)

let within (clock : Httpkit_transport_lwt.clock) seconds f =
  let work = Lwt.apply f () in
  let timer =
    Lwt.apply
      (fun () -> clock.sleep seconds >>= fun () -> Lwt.fail Lwt_unix.Timeout)
      ()
  in
  Lwt.finalize
    (fun () -> Lwt.choose [ work; timer ])
    (fun () ->
      (* Cancel both owned branches, then join their possibly suspended cleanup.
         Keep the winning result or failure from the race. *)
      Lwt.cancel work;
      Lwt.cancel timer;
      Lwt.join [ settle work; settle timer ])
