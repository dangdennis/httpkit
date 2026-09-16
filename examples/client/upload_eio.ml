let () =
  if Array.length Sys.argv <> 3 then (
    prerr_endline "usage: upload_eio URL FILE";
    exit 2);
  Mirage_crypto_rng_unix.use_default ();
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok a -> a
    | Error (`Msg m) -> failwith m
  in
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let source =
            Eio.Path.open_in ~sw Eio.Path.(Eio.Stdenv.fs env / Sys.argv.(2))
          in
          let buffer = Cstruct.create 32768 in
          let upload =
            Httpkit_client_eio.upload (fun () ->
                try
                  let n = Eio.Flow.single_read source buffer in
                  Some (Cstruct.to_string ~len:n buffer)
                with End_of_file -> None)
          in
          Httpkit_client_eio.with_response ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.mono_clock env)
            ~authenticator ~meth:Httpkit_core.Method.put ~upload Sys.argv.(1)
            (fun response body ->
              Printf.eprintf "HTTP %d\n%!"
                (Httpkit_core.Status.to_int
                   (Httpkit_core.Response.status response));
              let rec copy () =
                match Httpkit_client_eio.read body with
                | None -> ()
                | Some bytes ->
                    Eio.Flow.copy_string bytes (Eio.Stdenv.stdout env);
                    copy ()
              in
              copy ())))
