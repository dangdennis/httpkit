let ok = Result.get_ok

let read path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let cert ?(ip = false) () =
  ok
    (X509.Certificate.decode_pem
       (read
          (if ip then "../protocol_foundations/fixtures/loopback.pem"
           else "../protocol_foundations/fixtures/localhost.pem")))

let key () =
  ok
    (X509.Private_key.decode_pem
       (read "../protocol_foundations/fixtures/localhost.key"))

let authenticator ?(ip = false) trusted =
  X509.Authenticator.chain_of_trust
    ~time:(fun () -> Ptime.of_date_time ((2026, 9, 16), ((0, 0, 0), 0)))
    (if trusted then [ cert ~ip () ] else [])

let server ?(ip = false) () =
  ok
    (Tls.Config.server ~alpn_protocols:[ "http/1.1" ]
       ~certificates:(`Single ([ cert ~ip () ], key ()))
       ())

let wire =
  "HTTP/1.1 103 Hints\r\n\
   \r\n\
   HTTP/1.1 200 OK\r\n\
   Transfer-Encoding: chunked\r\n\
   Trailer: digest\r\n\
   \r\n\
   2\r\n\
   ab\r\n\
   1\r\n\
   c\r\n\
   0\r\n\
   digest: done\r\n\
   \r\n"

let short = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabc"
let unframed = "HTTP/1.1 200 OK\r\n\r\nabc"

let redirect =
  "HTTP/1.1 302 Found\r\n\
   Location: http://invalid.example/\r\n\
   Content-Length: 3\r\n\
   \r\n\
   abc"

let large =
  "HTTP/1.1 200 OK\r\nContent-Length: 200000\r\n\r\n" ^ String.make 200000 'x'
