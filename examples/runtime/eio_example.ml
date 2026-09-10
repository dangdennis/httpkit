module A = Http_kit_eio
module E = Http_kit_engine

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let a, b = Eio_unix.Net.socketpair_stream ~sw () in
          let clock = Eio.Stdenv.mono_clock env in
          Eio.Fiber.both
            (fun () ->
              A.with_connection ~clock (A.of_flow a)
                (Result.get_ok (E.server ()))
                (fun c ->
                  let id, request =
                    match A.next_event c with
                    | E.Request (id, r) -> (id, r)
                    | _ -> assert false
                  in
                  ignore (A.collect_body c id);
                  let response = Transform.handle request in
                  A.respond c id response;
                  A.send c id (Http_kit_core.Response.body response);
                  A.finish c id))
            (fun () ->
              A.with_connection ~clock (A.of_flow b)
                (Result.get_ok (E.client ()))
                (fun c ->
                  let open Http_kit_core in
                  let request =
                    Request.create ~meth:Method.get
                      ~target:(Result.get_ok (Target.of_string "/"))
                      ~headers:
                        (Result.get_ok
                           (Headers.of_list [ ("host", "localhost") ]))
                      ()
                  in
                  let id = A.submit_request c request in
                  A.finish c id;
                  (match A.next_event c with
                  | E.Response _ -> ()
                  | _ -> assert false);
                  let body, _ = A.collect_body c id in
                  print_string body))))
