open Httpkit_core

let response request body =
  let target = Target.to_string (Request.target request) in
  let payload =
    Printf.sprintf "%s %s %d %s\n"
      (Method.to_string (Request.meth request))
      target (String.length body)
      (Digest.to_hex (Digest.string body))
  in
  let chunked = target = "/chunked" in
  let headers =
    Result.get_ok
      (Headers.of_list
         ((if chunked then [ ("transfer-encoding", "chunked") ]
           else [ ("content-length", string_of_int (String.length payload)) ])
         @ [ ("set-cookie", "a=1"); ("set-cookie", "b=2") ]))
  in
  Response.create ~status:Status.ok ~headers payload
