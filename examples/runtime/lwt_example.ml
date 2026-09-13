open Lwt.Syntax
module A = Httpkit_transport_lwt
module E = Httpkit_engine

let () =
  Lwt_main.run
    (let a, b = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* (), () =
       Lwt.both
         (A.with_connection (A.of_fd a)
            (Result.get_ok (E.server ()))
            (fun c ->
              let* event = A.next_event c in
              let id, request =
                match event with
                | E.Request (id, r) -> (id, r)
                | _ -> assert false
              in
              let* _ = A.collect_body c id in
              let response = Transform.handle request in
              let* () = A.respond c id response in
              let* () = A.send c id (Httpkit_core.Response.body response) in
              A.finish c id))
         (A.with_connection (A.of_fd b)
            (Result.get_ok (E.client ()))
            (fun c ->
              let open Httpkit_core in
              let request =
                Request.create ~meth:Method.get
                  ~target:(Result.get_ok (Target.of_string "/"))
                  ~headers:
                    (Result.get_ok (Headers.of_list [ ("host", "localhost") ]))
                  ()
              in
              let* id = A.submit_request c request in
              let* () = A.finish c id in
              let* event = A.next_event c in
              (match event with E.Response _ -> () | _ -> assert false);
              let* body, _ = A.collect_body c id in
              print_string body;
              Lwt.return_unit))
     in
     Lwt.return_unit)
