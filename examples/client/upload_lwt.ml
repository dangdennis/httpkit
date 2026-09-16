open Lwt.Syntax

let () =
  if Array.length Sys.argv <> 3 then (
    prerr_endline "usage: upload_lwt URL FILE";
    exit 2);
  Mirage_crypto_rng_unix.use_default ();
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok a -> a
    | Error (`Msg m) -> failwith m
  in
  Lwt_main.run
    (Lwt_io.with_file ~mode:Lwt_io.input Sys.argv.(2) (fun source ->
         let upload =
           Httpkit_client_lwt.upload (fun () ->
               let* bytes = Lwt_io.read ~count:32768 source in
               Lwt.return (if bytes = "" then None else Some bytes))
         in
         Httpkit_client_lwt.with_response ~authenticator
           ~meth:Httpkit_core.Method.put ~upload Sys.argv.(1)
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
             copy ())))
