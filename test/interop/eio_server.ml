module A = Httpkit_transport_eio
module E = Httpkit_engine

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
          Printf.printf "%d\n%!" port;
          A.serve_connections ~max_connections:16
            ~clock:(Eio.Stdenv.mono_clock env)
            ~accept:(fun () ->
              let flow, _ = Eio.Net.accept ~sw socket in
              A.of_flow flow)
            ~on_error:(fun _ -> ())
            (fun c ->
              let rec loop () =
                match A.next_event c with
                | E.Request (id, request) ->
                    let body, _ = A.collect_body c id in
                    let response = Subject.response request body in
                    A.respond c id response;
                    if
                      Httpkit_core.Request.meth request
                      <> Httpkit_core.Method.head
                    then A.send c id (Httpkit_core.Response.body response);
                    A.finish c id;
                    loop ()
                | E.Closed _ -> ()
                | _ -> failwith "unexpected event"
              in
              loop ())))
