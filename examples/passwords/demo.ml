module Worker = Password_example_worker.Worker
module Password = Httpkit_password

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let worker = Worker.create ~sw (Eio.Stdenv.domain_mgr env) in
          let policy = Password.create () in
          (* Capture entropy on the application domain; no Eio resource or
             mutable RNG state is passed into the worker callback. *)
          let salt = Cstruct.create 16 in
          Eio.Flow.read_exact (Eio.Stdenv.secure_random env) salt;
          let salt = Cstruct.to_string salt in
          let result =
            Worker.run worker (fun () ->
                Password.hash policy
                  ~random:(fun n ->
                    assert (n = 16);
                    salt)
                  "synthetic demonstration password")
          in
          match result with
          | Ok (Ok encoded) ->
              let verified =
                Worker.run worker (fun () ->
                    Password.verify policy ~encoded
                      "synthetic demonstration password")
              in
              if verified <> Ok (Ok true) then failwith "verification failed";
              print_endline "PASS bounded password hashing and verification"
          | _ -> failwith "hashing failed"))
