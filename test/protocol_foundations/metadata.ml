open Httpkit_core

type protocol = Http1 of Version.t | Http2 | Http3

type t = {
  protocol : protocol;
  meth : Method.t;
  target : Target.t;
  scheme : string;
  authority : string;
  headers : Headers.t;
}

let of_http1 ~scheme ~authority request =
  {
    protocol = Http1 (Request.version request);
    meth = Request.meth request;
    target = Request.target request;
    scheme;
    authority;
    headers = Request.headers request;
  }

let of_http2 (request : H2.Request.t) =
  let ( let* ) = Result.bind in
  let* meth = Method.of_string (H2.Method.to_string request.meth) in
  let* target = Target.of_string request.target in
  let fields = H2.Headers.to_list request.headers in
  let authority =
    Option.value ~default:"" (List.assoc_opt ":authority" fields)
  in
  (* h2 owns pseudo-header validation. They are separate metadata here, not
     ordinary HTTP/1 header fields. This prototype is not a validator. *)
  let* headers =
    Headers.of_list
      (List.filter (fun (name, _) -> name = "" || name.[0] <> ':') fields)
  in
  Ok
    {
      protocol = Http2;
      meth;
      target;
      scheme = request.scheme;
      authority;
      headers;
    }

let protocol t = t.protocol
let meth t = t.meth
let target t = t.target
let scheme t = t.scheme
let authority t = t.authority
let headers t = t.headers
