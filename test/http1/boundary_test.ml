open Http_kit_core
module C = Http_kit_http1

let ok = Result.get_ok

let rejected = function
  | Error _ -> ()
  | Ok _ -> failwith "invalid input accepted"

let request ?(meth = Method.get) ?(target = "/") fields =
  Request.create ~meth
    ~target:(ok (Target.of_string target))
    ~headers:(ok (Headers.of_list fields))
    ()

let response ?(version = Version.Http_1_1) status fields =
  Response.create ~version
    ~status:(ok (Status.of_int status))
    ~headers:(ok (Headers.of_list fields))
    ()

let parse role wire =
  let d = C.head_decoder role in
  let rec loop off =
    match C.feed_head d wire ~off ~len:(String.length wire - off) with
    | Ok (n, Some m) -> Ok (d, m, n + off)
    | Ok (n, None) when n > 0 -> loop (off + n)
    | Ok _ -> Error C.Unexpected_eof
    | Error e -> Error e
  in
  loop 0

let meta fields = snd (ok (C.encode_request (request fields)))

let consume ?(limits = C.default_limits) metadata wire =
  let d = C.body_decoder ~limits metadata in
  let rec loop off fuel =
    assert (fuel > 0);
    match C.feed_body d wire ~off ~len:(String.length wire - off) with
    | Ok (_, Some C.End) -> Ok d
    | Ok (n, Some _) -> loop (off + n) (fuel - 1)
    | Ok (n, None) when n > 0 -> loop (off + n) (fuel - 1)
    | Ok _ -> Error C.Unexpected_eof
    | Error e -> Error e
  in
  loop 0 ((2 * String.length wire) + 10)

let diagnostics () =
  List.iter
    (fun e ->
      let s = C.error_to_string e in
      assert (String.length s > 0 && String.length s < 64))
    C.
      [
        Invalid_slice;
        Invalid_state;
        Invalid_line;
        Invalid_field;
        Unsupported_version;
        Invalid_target;
        Invalid_host;
        Ambiguous_framing;
        Invalid_length;
        Unsupported_coding;
        Unsupported_expectation;
        Invalid_chunk;
        Invalid_trailer;
        Limit_exceeded;
        Unexpected_eof;
      ];
  assert (Version.to_string Version.Http_1_0 = "HTTP/1.0");
  assert (Version.to_string Version.Http_1_1 = "HTTP/1.1")

let limits () =
  List.iter rejected
    [
      C.limits ~line:1 ();
      C.limits ~headers:3 ();
      C.limits ~fields:(-1) ();
      C.limits ~trailers:1 ();
      C.limits ~trailer_fields:(-1) ();
      C.limits ~chunk_line:2 ();
      C.limits ~step:0 ();
      C.limits ~body:(-1L) ();
    ];
  rejected
    (C.encode_request
       ~limits:(ok (C.limits ~body:2L ()))
       (request [ ("host", "x"); ("content-length", "3") ]));
  rejected
    (C.encode_request
       ~limits:(ok (C.limits ~line:12 ()))
       (request [ ("host", "x") ]));
  rejected
    (C.encode_request
       ~limits:(ok (C.limits ~line:20 ()))
       (request [ ("host", "x"); ("x", String.make 21 'a') ]));
  rejected
    (C.encode_response
       ~limits:(ok (C.limits ~fields:0 ()))
       ~request_method:Method.get
       (response 200 [ ("x", "a") ]));
  rejected
    (C.encode_response
       ~limits:(ok (C.limits ~headers:4 ()))
       ~request_method:Method.get (response 200 []));
  rejected
    (C.encode_response ~request_method:Method.get
       (response ~version:Version.Http_1_0 200 []))

let authorities () =
  List.iter
    (fun host -> rejected (C.encode_request (request [ ("host", host) ])))
    [
      "";
      "[";
      "[]";
      "[::1]x";
      "x:";
      "x:65536";
      "x:+80";
      "-x";
      "x-";
      "x..y";
      "x_y";
      ".x";
      "x.";
    ];
  List.iter
    (fun target ->
      rejected (C.encode_request (request ~target [ ("host", "x") ])))
    [ "/[x]"; "ftp://x/"; "http://x/[a]"; "https://y/" ];
  rejected
    (C.encode_request
       (request ~meth:Method.connect ~target:"x:443" [ ("host", "y:443") ]));
  List.iter
    (fun (target, host) ->
      ignore (ok (C.encode_request (request ~target [ ("host", host) ]))))
    [
      ("https://X/", "x:443");
      ("http://x?y", "x:80");
      ("https://x", "x");
      ("http://[::1]/", "[::1]:80");
    ];
  ignore
    (ok
       (C.encode_request
          (request ~meth:Method.connect ~target:"[::1]:443"
             [ ("host", "[::1]:443") ])))

let response_lines () =
  List.iter
    (fun first -> rejected (parse (C.Response Method.get) (first ^ "\r\n\r\n")))
    [
      "HTTP/1.0 200 OK";
      "HTTP/1.1_200 OK";
      "HTTP/1.1 200_OK";
      "HTTP/1.1 20 OK";
      "HTTP/1.1 200 bad\127";
      "HTTP/1.1 200 bad\000";
    ];
  rejected (parse C.Request "GET / HTTP/1.1\rXHost: x\r\n\r\n");
  rejected
    (parse C.Request "GET / HTTP/1.1\r\nHost: x\r\nmissing-colon\r\n\r\n");
  rejected
    (C.encode_request (request [ ("host", "x"); ("content-length", "") ]));
  rejected (C.encode_request (request [ ("host", "x"); ("trailer", "digest") ]));
  List.iter
    (fun (status, meth) ->
      List.iter
        (fun fields ->
          rejected
            (C.encode_response ~request_method:meth (response status fields)))
        [ [ ("content-length", "0") ]; [ ("transfer-encoding", "chunked") ] ])
    [ (100, Method.get); (204, Method.get); (200, Method.connect) ]

let chunked () =
  let metadata =
    meta
      [ ("host", "x"); ("transfer-encoding", "chunked"); ("trailer", "digest") ]
  in
  List.iter
    (fun wire -> ignore (ok (consume metadata wire)))
    [
      "a\r\n0123456789\r\n0\r\n\r\n";
      "A; a=\"x\\\"y\";z\r\n0123456789\r\n0\r\nDigest: x\r\n\r\n";
      "0; a=b\r\n\r\n";
    ];
  List.iter
    (fun wire -> rejected (consume metadata wire))
    [
      "1x\r\na\r\n0\r\n\r\n";
      "1; a=\r\na\r\n";
      "1; a=\"x\\\001\"\r\n";
      "1; a=\"x\001\"\r\n";
      "1\r\na\rX";
      "0\r\nDigest: x\rX";
    ];
  rejected
    (consume ~limits:(ok (C.limits ~body:0L ())) metadata "1\r\na\r\n0\r\n\r\n");
  rejected
    (consume
       ~limits:(ok (C.limits ~trailers:2 ()))
       metadata "0\r\nDigest: x\r\n\r\n");
  rejected
    (consume
       ~limits:(ok (C.limits ~trailer_fields:0 ()))
       metadata "0\r\nDigest: x\r\n\r\n")

let lifecycle () =
  let d, _, _ = ok (parse C.Request "GET / HTTP/1.1\r\nHost: x\r\n\r\n") in
  assert (C.eof_head d = Ok ());
  rejected (C.feed_head d "" ~off:0 ~len:0);
  let d = C.head_decoder C.Request in
  rejected (C.feed_head d "\n" ~off:0 ~len:1);
  rejected (C.eof_head d);
  let fixed = meta [ ("host", "x"); ("content-length", "1") ] in
  let d = C.body_decoder fixed in
  rejected (C.feed_body d "" ~off:(-1) ~len:0);
  rejected (C.eof_body d);
  let d = ok (consume fixed "a") in
  assert (C.eof_body d = Ok None);
  rejected (C.feed_body d "" ~off:0 ~len:0);
  let tunnel =
    snd
      (ok (C.encode_response ~request_method:Method.connect (response 200 [])))
  in
  let d = C.body_decoder tunnel in
  rejected (C.feed_body d "tls" ~off:0 ~len:3);
  rejected (C.eof_body (C.body_decoder tunnel));
  rejected (C.encode_data (C.body_encoder tunnel) "a");
  rejected (C.finish_body (C.body_encoder tunnel));
  let close =
    snd (ok (C.encode_response ~request_method:Method.get (response 200 [])))
  in
  let encoder = C.body_encoder close in
  assert (C.encode_data encoder "abc" = Ok "abc");
  assert (C.finish_body encoder = Ok "");
  let decoder = C.body_decoder close in
  assert (C.eof_body decoder = Ok (Some C.End));
  assert (C.eof_body decoder = Ok None);
  let empty = meta [ ("host", "x") ] in
  rejected (C.encode_data (C.body_encoder empty) "a");
  let encoder = C.body_encoder ~limits:(ok (C.limits ~step:1 ())) fixed in
  rejected (C.encode_data encoder "ab");
  rejected (C.finish_body encoder);
  rejected
    (C.finish_body
       ~trailers:(ok (Headers.of_list [ ("digest", "x") ]))
       (C.body_encoder fixed));
  let chunked =
    meta
      [ ("host", "x"); ("transfer-encoding", "chunked"); ("trailer", "digest") ]
  in
  List.iter
    (fun cfg ->
      rejected
        (C.finish_body
           ~trailers:(ok (Headers.of_list [ ("digest", "abcdef") ]))
           (C.body_encoder ~limits:cfg chunked)))
    [
      ok (C.limits ~trailer_fields:0 ());
      ok (C.limits ~line:8 ());
      ok (C.limits ~trailers:3 ());
    ]

let trailer_membership () =
  List.iter
    (fun count ->
      let repeated token =
        String.concat "," (List.init count (fun _ -> token))
      in
      let wire trailer =
        "POST / HTTP/1.1\r\n\
         Host: x\r\n\
         Transfer-Encoding: chunked\r\n\
         Connection: " ^ repeated "x" ^ "\r\nTrailer: " ^ trailer ^ "\r\n\r\n"
      in
      ignore (ok (parse C.Request (wire (repeated "y"))));
      assert (
        parse C.Request (wire (repeated "y" ^ ",x")) = Error C.Invalid_trailer))
    [ 1; 10; 100; 1000; 3000 ]

let () =
  Alcotest.run "HTTP boundary regressions"
    [
      ( "public contracts",
        List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          [
            ("bounded diagnostics", diagnostics);
            ("trailer token membership scaling", trailer_membership);
            ("configuration and outbound limits", limits);
            ("authority and target forms", authorities);
            ("status lines and forbidden framing", response_lines);
            ("chunk extensions and trailer limits", chunked);
            ("terminal operations and EOF", lifecycle);
          ] );
    ]
