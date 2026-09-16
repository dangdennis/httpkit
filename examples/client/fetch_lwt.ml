open Lwt.Syntax

let main () =
  if Array.length Sys.argv <> 2 then (
    prerr_endline "usage: fetch_lwt URL";
    exit 2);
  Mirage_crypto_rng_unix.use_default ();
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok a -> a
    | Error (`Msg m) -> failwith m
  in
  Lwt_main.run
    (Httpkit_client_lwt.with_response ~authenticator Sys.argv.(1)
       (fun response body ->
         let* () =
           Lwt_io.eprintf "HTTP %d\n"
             (Httpkit_core.Status.to_int
                (Httpkit_core.Response.status response))
         in
         let rec copy () =
           let* chunk = Httpkit_client_lwt.read body in
           match chunk with
           | None -> Lwt.return_unit
           | Some bytes ->
               let* () = Lwt_io.write Lwt_io.stdout bytes in
               copy ()
         in
         copy ()))

let () =
  try main ()
  with Httpkit_transport_lwt.Error failure ->
    prerr_endline (Httpkit_transport_lwt.failure_to_string failure);
    exit 1
