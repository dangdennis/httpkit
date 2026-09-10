open Http_kit_core
open Http_kit_http1

let ok = function Ok x -> x | Error e -> failwith (error_to_string e)

let value = function
  | Ok x -> x
  | Error e -> failwith (Http_kit_core.Error.to_string e)

let () =
  let r =
    Response.create ~status:Status.ok
      ~headers:
        (value
           (Headers.of_list
              [
                ("transfer-encoding", "chunked");
                ("set-cookie", "a=1");
                ("set-cookie", "b=2");
              ]))
      ()
  in
  let head, meta = ok (encode_response ~request_method:Method.get r) in
  let writer = body_encoder meta in
  print_string head;
  print_string (ok (encode_data writer "abc"));
  print_string (ok (finish_body writer))
