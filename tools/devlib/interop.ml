open Common
open Network

let expected meth path body =
  Printf.sprintf "%s %s %d %s\n" meth path (String.length body)
    Digestif.MD5.(to_hex (digest_string body))

let backend runtime f =
  with_temp "httpkit-backend-" (fun directory ->
      with_server ~directory ~prefix:""
        [ Build.binary ("test/interop/" ^ runtime ^ "_server.exe") ]
        (fun port child _ ->
          let result = f (int_of_string port) child in
          require (Process.poll child = None) "Backend exited unexpectedly";
          result))

let nginx = root / ".toolchain/nginx/sbin/nginx"

let proxy upstream buffering f =
  with_temp "httpkit-nginx-" (fun directory ->
      let port = Databases.port () in
      let config =
        Printf.sprintf
          {|daemon off;
master_process off;
error_log stderr warn;
pid %s/nginx.pid;
events { worker_connections 128; }
http { access_log off; client_body_temp_path %s/body; proxy_temp_path %s/proxy;
server { listen 127.0.0.1:%d;
location / { proxy_pass http://127.0.0.1:%d; proxy_http_version 1.1;
proxy_set_header Host $http_host; proxy_set_header Connection "";
proxy_request_buffering %s; proxy_buffering %s; } } }
|}
          directory directory directory port upstream buffering buffering
      in
      write (directory / "nginx.conf") config;
      Process.with_child ~log:(directory / "nginx.log")
        [ nginx; "-p"; directory ^ "/"; "-c"; directory / "nginx.conf" ]
        (fun child ->
          let deadline = monotonic () +. 10. in
          let rec await () =
            require (Process.poll child = None) "Nginx exited during startup";
            try
              let c = connect ~timeout:0.2 port in
              close c
            with Unix.Unix_error _ | Error _ ->
              require (monotonic () < deadline) "Nginx readiness timeout";
              sleep 0.01;
              await ()
          in
          await ();
          f port))

let positive port =
  with_connection port (fun c ->
      List.iter
        (fun (meth, path, body, chunked) ->
          let r = request ~body ~chunked c meth path in
          require
            (r.status = 200
            && r.body = if meth = "HEAD" then "" else expected meth path body)
            ("HTTP reference mismatch: " ^ meth ^ " " ^ path);
          require
            (values "set-cookie" r = [ "a=1"; "b=2" ])
            "Duplicate Set-Cookie preservation")
        [
          ("GET", "/one", "", false);
          ("POST", "/fixed", String.make 100000 'a', false);
          ( "POST",
            "/chunked",
            String.concat "" (List.init 1000 (fun _ -> "abc")),
            true );
          ("HEAD", "/head", "", false);
          ("GET", "/after-head", "", false);
        ]);
  let out =
    Process.output
      [
        "curl";
        "--silent";
        "--show-error";
        "--fail";
        "--max-time";
        "5";
        Printf.sprintf "http://127.0.0.1:%d/curl" port;
      ]
  in
  require (out = expected "GET" "/curl" "") "Curl interop";
  6

let marker = "GET /marker HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

let bad =
  [
    ( "cl-te",
      "POST /bad HTTP/1.1\r\n\
       Host: x\r\n\
       Content-Length: 4\r\n\
       Transfer-Encoding: chunked\r\n\
       \r\n\
       0\r\n\
       \r\n" );
    ( "duplicate-cl",
      "POST /bad HTTP/1.1\r\n\
       Host: x\r\n\
       Content-Length: 0\r\n\
       Content-Length: 0\r\n\
       \r\n" );
    ("signed-cl", "POST /bad HTTP/1.1\r\nHost: x\r\nContent-Length: +0\r\n\r\n");
    ( "te-chain",
      "POST /bad HTTP/1.1\r\n\
       Host: x\r\n\
       Transfer-Encoding: gzip, chunked\r\n\
       \r\n\
       0\r\n\
       \r\n" );
    ("obs-fold", "GET /bad HTTP/1.1\r\nHost: x\r\nX: a\r\n b\r\n\r\n");
    ( "bad-chunk",
      "POST /bad HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n"
    );
  ]

let lane port name =
  let count = positive port in
  let findings =
    List.map
      (fun (case, prefix) ->
        let result = exchange port (prefix ^ marker) in
        require
          ((not (contains result "/marker")) && not (contains result " 200 "))
          ("Malformed request accepted: " ^ name ^ "/" ^ case);
        let line = List.hd (String.split_on_char '\r' result) in
        `Assoc
          [
            ("case", `String case);
            ("classification", `String "rejected_without_marker");
            ( "response_status",
              `String (String.sub line 0 (min 80 (String.length line))) );
          ])
      bad
  in
  let wire =
    exchange port ("GET /first HTTP/1.1\r\nHost: x\r\n\r\n" ^ marker)
  in
  let count_headers =
    List.length
      (Str.full_split (Str.regexp_string "HTTP/1.1 200 ") wire
      |> List.filter (function Str.Delim _ -> true | _ -> false))
  in
  require
    (count_headers = 2
    && Str.search_forward (Str.regexp_string "/first") wire 0
       < Str.search_forward (Str.regexp_string "/marker") wire 0)
    "Pipeline ordering";
  let half =
    exchange ~half_close:true port
      "GET /half HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
  in
  require
    (contains half "/half" || ((not (ends ~suffix:"/direct" name)) && half = ""))
    "Half-close handling";
  `Assoc
    [
      ("lane", `String name);
      ("positive_requests", `Int count);
      ("pipeline_responses", `Int 2);
      ("framing_cases", `List findings);
      ( "half_close",
        `String
          (if contains half "/half" then "response_completed"
           else "proxy_cancelled_upstream_on_client_abort") );
    ]

let main () =
  require (Sys.file_exists nginx) "Nginx missing: mise run setup:nginx";
  let r = Process.run [ nginx; "-v" ] in
  let version = String.trim (r.stdout ^ r.stderr) in
  require (version = "nginx version: nginx/1.30.4") "Wrong Nginx version";
  Build.call
    [ "build"; "test/interop/eio_server.exe"; "test/interop/lwt_server.exe" ];
  let digest = Build.source_hash () in
  let results =
    List.concat_map
      (fun runtime ->
        backend runtime (fun port _ ->
            lane port (runtime ^ "/direct")
            :: List.map
                 (fun buffering ->
                   proxy port buffering (fun port ->
                       lane port (runtime ^ "/nginx-buffering-" ^ buffering)))
                 [ "on"; "off" ]))
      [ "eio"; "lwt" ]
  in
  require (Build.source_hash () = digest) "Sources changed during interop";
  Build.record "interop-5.5.0.json"
    [
      ("status", `String "PASS");
      ("compiler", `String Build.version);
      ("nginx", `String version);
      ( "curl",
        `String (List.hd (lines (Process.output [ "curl"; "--version" ]))) );
      ("client", `String "OCaml + independent http/af parser and curl");
      ("results", `List results);
      ( "limitations",
        strings
          [
            "One pinned intermediary; Caddy ingress, forwarded identity and \
             long soak are not covered.";
          ] );
    ];
  print_endline "PASS six direct/Nginx interop lanes"

let routing () =
  Build.call
    [
      "build";
      "examples/routing/eio_server.exe";
      "examples/routing/lwt_server.exe";
    ];
  List.iter
    (fun runtime ->
      with_temp "httpkit-routing-" (fun directory ->
          with_server ~directory ~prefix:"http://127.0.0.1:"
            [ Build.binary ("examples/routing/" ^ runtime ^ "_server.exe") ]
            (fun value _ _ ->
              let port = int_of_string (String.trim value) in
              with_connection port (fun c ->
                  List.iter
                    (fun (meth, path, body, status, payload, allow) ->
                      let r = request ~body c meth path in
                      require
                        (r.status = status && r.body = payload
                        && header "x-example" r = "httpkit"
                        && header "allow" r = allow)
                        ("Routing response: " ^ path))
                    [
                      ("GET", "/", "", 200, "Hello /\n", "");
                      ("GET", "/users/me", "", 200, "Current user\n", "");
                      ("GET", "/users/123?view=full", "", 200, "User 123\n", "");
                      ("GET", "/users/%2F", "", 200, "User %2F\n", "");
                      ("GET", "/files/a//b", "", 200, "Raw path: a//b\n", "");
                      ("GET", "/missing", "", 404, "Not found\n", "");
                      ( "POST",
                        "/users/123",
                        "",
                        405,
                        "Method not allowed\n",
                        "GET" );
                      ("HEAD", "/users/123", "", 405, "", "GET");
                      ( "POST",
                        "/echo",
                        "body\000bytes",
                        200,
                        "body\000bytes",
                        "" );
                      ("GET", "/", "", 200, "Hello /\n", "");
                    ];
                  List.iter
                    (fun (headers, status, payload) ->
                      let r = request ~headers c "GET" "/protected" in
                      require
                        (r.status = status && r.body = payload)
                        "Protected route")
                    [
                      ([], 401, "Demo identity required\n");
                      ([ ("x-demo-user", "demo") ], 200, "Hello demo\n");
                    ]);
              List.iter
                (fun (target, status) ->
                  with_connection port (fun c ->
                      send c
                        ("POST " ^ target
                       ^ " HTTP/1.1\r\n\
                          Host: x\r\n\
                          Expect: 100-continue\r\n\
                          Content-Length: 4\r\n\
                          \r\n");
                      let first = head c in
                      require
                        (starts ~prefix:("HTTP/1.1 " ^ status) first)
                        "Expect decision";
                      if status = "100" then (
                        send c "body";
                        let r = response c "POST" in
                        require
                          (r.status = 200 && r.body = "body")
                          "Expect final body")))
                [ ("/echo", "100"); ("/missing", "404") ];
              Printf.printf
                "PASS %s routing/middleware over persistent HTTP\n%!" runtime)))
    [ "eio"; "lwt" ]
