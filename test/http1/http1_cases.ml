open Http_kit_core
open Http_kit_http1

let check b s = if not b then failwith s
let ok = function Ok x -> x | Error e -> failwith (error_to_string e)

let value = function
  | Ok x -> x
  | Error e -> failwith (Http_kit_core.Error.to_string e)

let request ?(target = "/") ?(meth = Method.get) hs =
  Request.create ~meth
    ~target:(value (Target.of_string target))
    ~headers:(value (Headers.of_list hs))
    ()

let response status hs =
  Response.create
    ~status:(value (Status.of_int status))
    ~headers:(value (Headers.of_list hs))
    ()

let parse ?(limits = default_limits) role wire split =
  let decoder = head_decoder ~limits role in
  let rec loop pos =
    let len = if pos < split then split - pos else String.length wire - pos in
    match feed_head decoder wire ~off:pos ~len with
    | Error e ->
        check
          (feed_head decoder "GET / HTTP/1.1\r\nHost: good\r\n\r\n" ~off:0
             ~len:30
          = Error e)
          "failed head reused";
        Error e
    | Ok (n, Some h) -> Ok (pos + n, h)
    | Ok (0, None) ->
        let* () = eof_head decoder in
        Error Unexpected_eof
    | Ok (n, None) -> loop (pos + n)
  and ( let* ) = Result.bind in
  loop 0

let body ?(limits = default_limits) meta wire split =
  let decoder = body_decoder ~limits meta in
  let rec loop pos data trailers calls =
    if calls > 100000 then failwith "unbounded body work";
    let len = if pos < split then split - pos else String.length wire - pos in
    let* n, event = feed_body decoder wire ~off:pos ~len in
    match event with
    | Some End -> Ok (pos + n, String.concat "" (List.rev data), trailers)
    | Some (Data bytes) -> loop (pos + n) (bytes :: data) trailers (calls + 1)
    | Some (Trailers hs) -> loop (pos + n) data (Headers.to_list hs) (calls + 1)
    | None when n = 0 -> (
        match eof_body decoder with
        | Ok (Some End) -> Ok (pos, String.concat "" (List.rev data), trailers)
        | Error e -> Error e
        | _ -> failwith "missing end")
    | None -> loop (pos + n) data trailers (calls + 1)
  and ( let* ) = Result.bind in
  loop 0 [] [] 0

let valid_heads =
  [
    ( "origin",
      Request,
      "GET /a%2Fb?q=x HTTP/1.1\r\nHost: example.test\r\n\r\n",
      Empty );
    ( "absolute",
      Request,
      "GET http://EXAMPLE.test:80/a HTTP/1.1\r\nHost: example.test\r\n\r\n",
      Empty );
    ( "ipv6",
      Request,
      "CONNECT [::1]:443 HTTP/1.1\r\nHost: [0:0:0:0:0:0:0:1]:443\r\n\r\n",
      Empty );
    ( "asterisk",
      Request,
      "OPTIONS * HTTP/1.1\r\nHost: example.test\r\n\r\n",
      Empty );
    ( "fixed",
      Request,
      "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0003\r\n\r\n",
      Fixed 3L );
    ( "ows",
      Request,
      "GET / HTTP/1.1\r\nHost:\tx \t\r\nX: \t\255\t \r\n\r\n",
      Empty );
    ( "chunked",
      Request,
      "POST / HTTP/1.1\r\n\
       Host: x\r\n\
       Transfer-Encoding: CHUNKED\r\n\
       Trailer: Digest\r\n\
       \r\n",
      Chunked );
    ("continue", Response Method.post, "HTTP/1.1 100 Continue\r\n\r\n", Empty);
    ( "head",
      Response Method.head,
      "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\n",
      Empty );
    ( "not-modified",
      Response Method.get,
      "HTTP/1.1 304 Not Modified\r\nContent-Length: 999\r\n\r\n",
      Empty );
    ("no-content", Response Method.get, "HTTP/1.1 204 \r\n\r\n", Empty);
    ( "close-body",
      Response Method.get,
      "HTTP/1.1 200 Fine\r\n\r\n",
      Close_delimited );
    ("tunnel", Response Method.connect, "HTTP/1.1 200 OK\r\n\r\n", Tunnel);
  ]

let invalid_requests =
  [
    ("missing-host", "GET / HTTP/1.1\r\n\r\n");
    ("duplicate-host", "GET / HTTP/1.1\r\nHost: x\r\nHost: x\r\n\r\n");
    ("authority-conflict", "GET http://x/a HTTP/1.1\r\nHost: y\r\n\r\n");
    ("userinfo", "GET http://a@x/a HTTP/1.1\r\nHost: x\r\n\r\n");
    ("bad-ipv6", "GET / HTTP/1.1\r\nHost: [:::]\r\n\r\n");
    ("bad-port", "GET / HTTP/1.1\r\nHost: x:65536\r\n\r\n");
    ("connect-port", "CONNECT x HTTP/1.1\r\nHost: x\r\n\r\n");
    ("get-star", "GET * HTTP/1.1\r\nHost: x\r\n\r\n");
    ("bare-lf", "GET / HTTP/1.1\nHost: x\n\n");
    ("extra-space", "GET  / HTTP/1.1\r\nHost: x\r\n\r\n");
    ("http10", "GET / HTTP/1.0\r\nHost: x\r\n\r\n");
    ("h2-preface", "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    ("obs-fold", "GET / HTTP/1.1\r\nHost: x\r\n x: y\r\n\r\n");
    ("colon-space", "GET / HTTP/1.1\r\nHost : x\r\n\r\n");
    ("nul", "GET / HTTP/1.1\r\nHost: x\000y\r\n\r\n");
  ]
  @ List.map
      (fun (name, fields) ->
        (name, "POST / HTTP/1.1\r\nHost: x\r\n" ^ fields ^ "\r\n"))
      [
        ("cl-te", "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n");
        ("equal-cl", "Content-Length: 1\r\nContent-Length: 1\r\n");
        ("unequal-cl", "Content-Length: 1\r\nContent-Length: 2\r\n");
        ("comma-cl", "Content-Length: 1, 1\r\n");
        ("signed-cl", "Content-Length: +1\r\n");
        ("negative-cl", "Content-Length: -1\r\n");
        ("overflow-cl", "Content-Length: 9223372036854775808\r\n");
        ("junk-cl", "Content-Length: 1x\r\n");
        ("chain-te", "Transfer-Encoding: gzip, chunked\r\n");
        ( "double-te",
          "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n" );
        ("expectation", "Expect: unsupported\r\n");
        ( "forbidden-trailer",
          "Transfer-Encoding: chunked\r\nTrailer: Content-Length\r\n" );
        ("hop-framing", "Connection: content-length\r\nContent-Length: 1\r\n");
      ]

let invalid_requests =
  invalid_requests
  @ [
      ( "hop-trailer",
        "POST / HTTP/1.1\r\n\
         Host: x\r\n\
         Connection: digest\r\n\
         Transfer-Encoding: chunked\r\n\
         Trailer: digest\r\n\
         \r\n" );
    ]

let fixed_meta =
  snd
    (ok
       (encode_request
          (request ~meth:Method.post [ ("host", "x"); ("content-length", "3") ])))

let chunk_meta =
  snd
    (ok
       (encode_request
          (request ~meth:Method.post
             [
               ("host", "x");
               ("transfer-encoding", "chunked");
               ("trailer", "digest");
             ])))

let cases =
  List.map
    (fun (name, role, wire, framing) ->
      ( "http1/head/" ^ name,
        fun () ->
          for split = 0 to String.length wire do
            let n, meta = ok (parse role (wire ^ "NEXT") split) in
            check
              (n = String.length wire && meta.framing = framing)
              "head/suffix mismatch"
          done;
          for n = 0 to String.length wire - 1 do
            check
              (Result.is_error (parse role (String.sub wire 0 n) n))
              "truncated head accepted"
          done ))
    valid_heads
  @ List.map
      (fun (name, wire) ->
        ( "http1/reject/" ^ name,
          fun () ->
            for split = 0 to String.length wire do
              check
                (Result.is_error
                   (parse Request
                      (wire ^ "GET / HTTP/1.1\r\nHost: marker\r\n\r\n")
                      split))
                "invalid request dispatched"
            done ))
      invalid_requests
  @ [
      ( "http1/body/fragments",
        fun () ->
          List.iter
            (fun (meta, wire, expected, expected_end) ->
              for split = 0 to String.length wire do
                let n, data, _ = ok (body meta wire split) in
                check
                  (data = expected && n = expected_end)
                  "body/suffix mismatch"
              done)
            [
              (fixed_meta, "abcNEXT", "abc", 3);
              ( chunk_meta,
                "1;foo=\"a\\\"b\"\r\n\
                 a\r\n\
                 2;x=token\r\n\
                 bc\r\n\
                 0\r\n\
                 digest: yes\r\n\
                 \r\n\
                 NEXT",
                "abc",
                50 );
            ] );
      ( "http1/body/truncated",
        fun () ->
          List.iter
            (fun (meta, wire) ->
              for n = 0 to String.length wire - 1 do
                check
                  (Result.is_error (body meta (String.sub wire 0 n) n))
                  "truncated body completed"
              done)
            [ (fixed_meta, "abc"); (chunk_meta, "3\r\nabc\r\n0\r\n\r\n") ] );
      ( "http1/body/chunk-reject",
        fun () ->
          List.iter
            (fun wire ->
              check
                (Result.is_error (body chunk_meta wire 0))
                "invalid chunk accepted")
            [
              "g\r\n";
              "-1\r\n";
              "8000000000000000\r\n";
              "1;\r\na\r\n0\r\n\r\n";
              "1;x=\"unterminated\r\n";
              "1\r\naX\n0\r\n\r\n";
              "0\r\ncontent-length: 0\r\n\r\n";
              "0\r\nx-undeclared: yes\r\n\r\n";
              "0\r\n digest: x\r\n\r\n";
            ] );
      ( "http1/body/serialization",
        fun () ->
          let e = body_encoder chunk_meta in
          check (ok (encode_data e "") = "") "empty data terminated";
          check (ok (encode_data e "abc") = "3\r\nabc\r\n") "chunk bytes";
          check
            (ok
               (finish_body
                  ~trailers:(value (Headers.of_list [ ("digest", "yes") ]))
                  e)
            = "0\r\ndigest: yes\r\n\r\n")
            "trailer bytes";
          check (finish_body e = Error Invalid_state) "double end";
          let e = body_encoder fixed_meta in
          check (encode_data e "abcd" = Error Invalid_length) "overflow data";
          check (finish_body e = Error Invalid_state) "failed writer revived";
          let e = body_encoder fixed_meta in
          ignore (ok (encode_data e "ab"));
          check (finish_body e = Error Invalid_length) "short body finished" );
      ( "http1/head/serialization",
        fun () ->
          let wire, _ =
            ok
              (encode_request
                 (request [ ("Host", "example.test"); ("x", "y") ]))
          in
          check
            (wire = "GET / HTTP/1.1\r\nhost: example.test\r\nx: y\r\n\r\n")
            "request fixture";
          let wire, _ =
            ok
              (encode_response ~request_method:Method.get
                 (response 200 [ ("content-length", "0") ]))
          in
          check
            (wire = "HTTP/1.1 200 \r\ncontent-length: 0\r\n\r\n")
            "response fixture";
          check
            (Result.is_error
               (encode_request
                  (request
                     [
                       ("host", "x");
                       ("content-length", "1");
                       ("transfer-encoding", "chunked");
                     ])))
            "outbound smuggling";
          List.iter
            (fun status ->
              check
                (Result.is_error
                   (encode_response ~request_method:Method.get
                      (response status [ ("content-length", "0") ])))
                "bodyless framing")
            [ 100; 204 ] );
      ( "http1/limits",
        fun () ->
          let wire = "GET / HTTP/1.1\r\nHost: x\r\n\r\n" in
          ignore
            (ok
               (parse
                  ~limits:(ok (limits ~headers:(String.length wire) ~step:1 ()))
                  Request wire 0));
          check
            (Result.is_error
               (parse
                  ~limits:(ok (limits ~headers:(String.length wire - 1) ()))
                  Request wire 0))
            "head budget";
          check
            (Result.is_error
               (parse ~limits:(ok (limits ~fields:0 ())) Request wire 0))
            "field count";
          check
            (Result.is_error
               (body ~limits:(ok (limits ~body:2L ())) fixed_meta "abc" 0))
            "body quota";
          check
            (Result.is_error
               (body
                  ~limits:(ok (limits ~chunk_line:3 ()))
                  chunk_meta "1;x=y\r\na\r\n0\r\n\r\n" 0))
            "chunk line quota";
          check (limits ~step:0 () = Error Limit_exceeded) "zero work budget" );
      ( "http1/slices",
        fun () ->
          List.iter
            (fun (off, len) ->
              let d = head_decoder Request in
              check
                (feed_head d "abc" ~off ~len = Error Invalid_slice)
                "bad slice")
            [ (-1, 1); (0, -1); (2, 2); (max_int, 1); (1, max_int) ] );
      ( "http1/close-and-eof",
        fun () ->
          let _, meta =
            ok (encode_response ~request_method:Method.get (response 200 []))
          in
          check (not meta.persistent) "close-delimited reuse";
          let _, data, _ = ok (body meta "abc" 1) in
          check (data = "abc") "EOF data loss";
          let d = body_decoder fixed_meta in
          check (feed_body d "" ~off:0 ~len:0 = Ok (0, None)) "empty means EOF";
          check (eof_body d = Error Unexpected_eof) "short EOF accepted" );
    ]

let properties ~seed ~count =
  let open QCheck2 in
  [
    ( "http1/property-fragments",
      fun () ->
        Test.check_exn
          ~rand:(Random.State.make [| seed |])
          (Test.make ~count
             (Gen.pair (Gen.int_bound 1000) (Gen.int_bound 1000))
             (fun (a, b) ->
               let payload = String.make (a mod 129) 'x' in
               let meta =
                 snd
                   (ok
                      (encode_request
                         (request
                            [
                              ("host", "x");
                              ( "content-length",
                                string_of_int (String.length payload) );
                            ])))
               in
               let n, data, _ =
                 ok
                   (body
                      ~limits:(ok (limits ~step:(1 + (b mod 31)) ()))
                      meta (payload ^ "NEXT")
                      (min (String.length payload) (b mod 129)))
               in
               n = String.length payload && data = payload)) );
  ]
