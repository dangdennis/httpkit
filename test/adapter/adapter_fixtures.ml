open Httpkit_core

let ok = Result.get_ok
let get = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
let connect = "CONNECT x:443 HTTP/1.1\r\nHost: x:443\r\n\r\nTLS"

let request () =
  Request.create ~meth:Method.get
    ~target:(ok (Target.of_string "/"))
    ~headers:(ok (Headers.of_list [ ("host", "x") ]))
    ()

let response n =
  Response.create ~status:Status.ok
    ~headers:(ok (Headers.of_list [ ("content-length", string_of_int n) ]))
    ()

let tunnel () = Response.create ~status:Status.ok ()

let wire body =
  "HTTP/1.1 200 \r\ncontent-length: "
  ^ string_of_int (String.length body)
  ^ "\r\n\r\n" ^ body
