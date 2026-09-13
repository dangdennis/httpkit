open Lwt.Syntax
module A = Httpkit_transport_lwt
module E = Httpkit_engine

let () =
  Lwt_main.run
    (let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
     Lwt.finalize
       (fun () ->
         let* () =
           Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
         in
         Lwt_unix.listen socket 32;
         let port =
           match Lwt_unix.getsockname socket with
           | Unix.ADDR_INET (_, p) -> p
           | _ -> assert false
         in
         Printf.printf "%d\n%!" port;
         A.serve_connections ~max_connections:16
           ~accept:(fun () ->
             let* fd, _ = Lwt_unix.accept socket in
             Lwt.return (A.of_fd fd))
           ~on_error:(fun _ -> Lwt.return_unit)
           (fun c ->
             let rec loop () =
               let* event = A.next_event c in
               match event with
               | E.Request (id, request) ->
                   let* body, _ = A.collect_body c id in
                   let response = Subject.response request body in
                   let* () = A.respond c id response in
                   let* () =
                     if
                       Httpkit_core.Request.meth request
                       <> Httpkit_core.Method.head
                     then A.send c id (Httpkit_core.Response.body response)
                     else Lwt.return_unit
                   in
                   let* () = A.finish c id in
                   loop ()
               | E.Closed _ -> Lwt.return_unit
               | _ -> Lwt.fail_with "unexpected event"
             in
             loop ()))
       (fun () -> Lwt_unix.close socket))
