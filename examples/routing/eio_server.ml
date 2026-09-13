module A = Httpkit_transport_eio
module E = Httpkit_engine

let handle request =
  if Application.is_protected request then
    let authorize next () request =
      (* A native asynchronous decision can supply a richer context to next. *)
      Eio.Fiber.yield ();
      match Application.authenticate request with
      | Some user -> next user request
      | None -> Application.denied ()
    in
    Httpkit_middleware.Transition.compose authorize
      Httpkit_middleware.Transition.identity Application.protected () request
  else Application.handle request

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let socket =
            Eio.Net.listen ~sw ~backlog:32 (Eio.Stdenv.net env)
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr socket with
            | `Tcp (_, port) -> port
            | _ -> assert false
          in
          Printf.printf "http://127.0.0.1:%d\n%!" port;
          A.serve_connections ~max_connections:16
            ~clock:(Eio.Stdenv.mono_clock env)
            ~accept:(fun () ->
              let flow, _ = Eio.Net.accept ~sw socket in
              A.of_flow flow)
            ~on_error:(fun exn ->
              prerr_endline
                (match exn with
                | A.Error failure -> A.failure_to_string failure
                | _ -> Printexc.to_string exn))
            (fun c ->
              let rec loop () =
                match A.next_event c with
                | E.Request (id, request) ->
                    let response =
                      match Application.upload_policy request with
                      | `Reject response -> response
                      | `Consume ->
                          if Application.expects_continue request then
                            A.respond c id Application.continue_response;
                          let body, _ = A.collect_body ~limit:65536 c id in
                          handle (Httpkit_core.Request.with_body body request)
                    in
                    A.respond c id response;
                    if
                      Httpkit_core.Request.meth request
                      <> Httpkit_core.Method.head
                    then A.send c id (Httpkit_core.Response.body response);
                    A.finish c id;
                    loop ()
                | E.Body_aborted _ | E.Complete _ -> loop ()
                | E.Closed _ -> ()
                | _ -> failwith "unexpected event"
              in
              loop ())))
