module C = Httpkit_client
module H = Httpkit_core

let ok = Result.get_ok

let () =
  Alcotest.run "client URL policy"
    [
      ( "policy",
        [
          Alcotest.test_case "origin and query bytes" `Quick (fun () ->
              List.iter
                (fun (url, host, port, tls, target) ->
                  let e = ok (C.prepare url) in
                  assert (e.host = host && e.port = port && e.tls = tls);
                  assert (
                    H.Target.to_string (H.Request.target e.request) = target))
                [
                  ("http://example.org", "example.org", 80, false, "/");
                  ( "https://example.org:8443/a%2Fb?x=%2F&x=+",
                    "example.org",
                    8443,
                    true,
                    "/a%2Fb?x=%2F&x=+" );
                  ("http://[::1]:8080/?", "::1", 8080, false, "/?");
                ]);
          Alcotest.test_case "reject ambiguous URLs and controlled headers"
            `Quick (fun () ->
              List.iter
                (fun url ->
                  if Result.is_ok (C.prepare url) then
                    failwith ("accepted " ^ url))
                [
                  "/relative";
                  "ftp://x/a";
                  "http://user:pass@x/";
                  "http://x/#fragment";
                  "http://x:0/";
                  "http://x:65536/";
                  "http://x:bad/";
                  "http://x/a b";
                  "http://x/\r\ninjected";
                  "http://x\\evil/";
                  "http:///a";
                  "http://x:/";
                ];
              List.iter
                (fun name ->
                  assert (
                    Result.is_error
                      (C.prepare
                         ~headers:(ok (H.Headers.of_list [ (name, "x") ]))
                         "http://x/")))
                [
                  "host";
                  "Connection";
                  "content-length";
                  "transfer-encoding";
                  "expect";
                  "upgrade";
                  "trailer";
                  "te";
                ]);
          Alcotest.test_case "owned upload framing and origin isolation" `Quick
            (fun () ->
              let endpoint =
                ok
                  (C.prepare ~meth:H.Method.post ~body:(`Fixed 3L)
                     ~keep_alive:true "https://example.org/upload")
              in
              let wire, _ =
                ok (Httpkit_http1.encode_request endpoint.request)
              in
              assert (
                String.starts_with ~prefix:"POST /upload HTTP/1.1\r\n" wire);
              let get name =
                H.Headers.get_all
                  (ok (H.Header.Name.of_string name))
                  (H.Request.headers endpoint.request)
              in
              assert (
                List.length (get "content-length") = 1 && get "connection" = []);
              assert (
                Result.is_error (C.prepare ~body:(`Fixed (-1L)) "http://x/"));
              assert (
                Result.is_error (C.prepare ~meth:H.Method.connect "http://x/"));
              assert (
                Result.is_error
                  (C.prepare ~meth:H.Method.head ~body:`Chunked "http://x/"));
              assert (
                C.same_origin endpoint
                  (ok (C.prepare "https://EXAMPLE.org:443/elsewhere")));
              assert (
                not
                  (C.same_origin endpoint
                     (ok (C.prepare "http://example.org/"))));
              assert (
                not
                  (C.same_origin endpoint
                     (ok (C.prepare "https://example.org:444/")))));
          Alcotest.test_case "deadline validation" `Quick (fun () ->
              List.iter
                (fun v ->
                  try
                    C.check_timeout v;
                    assert false
                  with Invalid_argument _ -> ())
                [ 0.; -1.; infinity; nan ]);
        ] );
    ]
