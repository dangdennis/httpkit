open Support
open Httpkit_core

let run () =
  let fields = [ ("x-repeat", "one"); ("x-repeat", "two") ] in
  let headers = Result.get_ok (Headers.of_list fields) in
  let request =
    Request.create ~meth:Method.get
      ~target:(Result.get_ok (Target.of_string "/hello?q=1"))
      ~headers ()
  in
  let h1 = Metadata.of_http1 ~scheme:"https" ~authority:"localhost" request in
  require
    (Metadata.protocol h1 = Metadata.Http1 Version.Http_1_1)
    "HTTP/1 default changed";
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list ((":authority", "localhost") :: fields))
      `GET "/hello?q=1"
  in
  let h2 = Result.get_ok (Metadata.of_http2 request) in
  require (Metadata.protocol h2 = Metadata.Http2) "HTTP/2 disguised as HTTP/1";
  require
    (Metadata.scheme h2 = "https" && Metadata.authority h2 = "localhost")
    "Authority/scheme lost";
  require
    (Target.to_string (Metadata.target h2) = "/hello?q=1")
    "Target changed";
  require
    (Headers.to_list (Metadata.headers h2) = Headers.to_list headers)
    "Repeated field order changed";
  `String "PASS"
