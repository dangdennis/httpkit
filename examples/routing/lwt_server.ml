open Lwt.Syntax
module A = Http_kit_lwt
module E = Http_kit_engine

let handle request =
  if Application.is_protected request then
    let authorize next () request =
      let* () = Lwt.pause () in
      match Application.authenticate request with
      | Some user -> next user request
      | None -> Lwt.return (Application.denied ())
    in
    let endpoint user request =
      Lwt.return (Application.protected user request)
    in
    Http_kit_middleware.Transition.compose authorize
      Http_kit_middleware.Transition.identity endpoint () request
  else Lwt.return (Application.handle request)

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
         Printf.printf "http://127.0.0.1:%d\n%!" port;
         A.serve_connections ~max_connections:16
           ~accept:(fun () ->
             let* fd, _ = Lwt_unix.accept socket in
             Lwt.return (A.of_fd fd))
           ~on_error:(fun exn ->
             prerr_endline
               (match exn with
               | A.Error failure -> A.failure_to_string failure
               | _ -> Printexc.to_string exn);
             Lwt.return_unit)
           (fun c ->
             let rec loop () =
               let* event = A.next_event c in
               match event with
               | E.Request (id, request) ->
                   let* response =
                     match Application.upload_policy request with
                     | `Reject response -> Lwt.return response
                     | `Consume ->
                         let* () =
                           if Application.expects_continue request then
                             A.respond c id Application.continue_response
                           else Lwt.return_unit
                         in
                         let* body, _ = A.collect_body ~limit:65536 c id in
                         handle (Http_kit_core.Request.with_body body request)
                   in
                   let* () = A.respond c id response in
                   let* () =
                     if
                       Http_kit_core.Request.meth request
                       <> Http_kit_core.Method.head
                     then A.send c id (Http_kit_core.Response.body response)
                     else Lwt.return_unit
                   in
                   let* () = A.finish c id in
                   loop ()
               | E.Body_aborted _ | E.Complete _ -> loop ()
               | E.Closed _ -> Lwt.return_unit
               | _ -> Lwt.fail_with "unexpected event"
             in
             loop ()))
       (fun () -> Lwt_unix.close socket))
