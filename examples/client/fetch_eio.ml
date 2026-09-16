let () =
  if Array.length Sys.argv <> 2 then (
    prerr_endline "usage: fetch_eio URL";
    exit 2);
  Mirage_crypto_rng_unix.use_default ();
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok a -> a
    | Error (`Msg m) -> failwith m
  in
  Eio_main.run (fun env ->
      Httpkit_client_eio.with_response ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.mono_clock env) ~authenticator Sys.argv.(1)
        (fun response body ->
          Printf.eprintf "HTTP %d\n%!"
            (Httpkit_core.Status.to_int (Httpkit_core.Response.status response));
          let rec copy () =
            match Httpkit_client_eio.read body with
            | None -> ()
            | Some bytes ->
                Eio.Flow.copy_string bytes (Eio.Stdenv.stdout env);
                copy ()
          in
          copy ()))
