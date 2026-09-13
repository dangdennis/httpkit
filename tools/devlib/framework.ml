open Common
open Network

type app = {
  port : int;
  child : Process.child;
  log : string;
  mutable final : Yojson.Basic.t option;
  mutable closed : bool;
}

let close app =
  if not app.closed then (
    if Process.poll app.child = None then Process.signal app.child Sys.sigterm;
    let status =
      Fun.protect
        ~finally:(fun () -> Process.stop app.child)
        (fun () -> Process.wait app.child (monotonic () +. 15.))
    in
    app.closed <- true;
    require (Process.status_code status = 0) "Framework server shutdown failed";
    let ls = lines (read app.log) in
    app.final <-
      (match List.rev ls with
      | last :: _ -> (
          try Some (Yojson.Basic.from_string last) with _ -> None)
      | [] -> None))

let with_app ?database_uri ~binary ~directory f =
  let public = directory / "public" in
  mkdir public;
  write (public / "hello.txt") "static contents\n";
  write (directory / "private.txt") "PRIVATE SENTINEL";
  Unix.symlink (directory / "private.txt") (public / "escape.txt");
  let env =
    environment ()
    |> List.filter (fun (k, _) ->
        (not (starts ~prefix:"PG" k)) && k <> "DATABASE_URL")
  in
  let env =
    List.fold_left
      (fun env (k, v) -> set env k v)
      env
      [
        ("PORT", "0");
        ("APP_ORIGIN", "https://app.example");
        ("STATIC_ROOT", public);
        ("DEMO_LOGIN_TOKEN", "synthetic-test-token");
        ("FRAMEWORK_TEST_MODE", "1");
      ]
  in
  let env =
    match database_uri with
    | None -> env
    | Some uri -> set env "DATABASE_URL" uri
  in
  with_server ~env ~directory ~prefix:"LISTEN "
    [ absolute binary ]
    (fun value child log ->
      let app =
        { port = int_of_string value; child; log; final = None; closed = false }
      in
      Fun.protect ~finally:(fun () -> close app) (fun () -> f app))

let request ?body ?headers ?connection app meth path =
  match connection with
  | Some c -> Network.request ?body ?headers c meth path
  | None ->
      with_connection app.port (fun c ->
          Network.request ?body ?headers c meth path)

let frame ?(fin = true) op data =
  let n = String.length data and mask = "1234" in
  let b = Buffer.create (String.length data + 14) in
  Buffer.add_char b (Char.chr ((if fin then 128 else 0) lor op));
  if n < 126 then Buffer.add_char b (Char.chr (128 lor n))
  else if n < 65536 then (
    Buffer.add_char b '\254';
    Buffer.add_char b (Char.chr (n lsr 8));
    Buffer.add_char b (Char.chr (n land 255)))
  else (
    Buffer.add_char b '\255';
    for i = 7 downto 0 do
      Buffer.add_char b
        (Char.chr
           (Int64.to_int
              (Int64.logand
                 (Int64.shift_right_logical (Int64.of_int n) (i * 8))
                 255L)))
    done);
  Buffer.add_string b mask;
  String.iteri
    (fun i c ->
      Buffer.add_char b (Char.chr (Char.code c lxor Char.code mask.[i mod 4])))
    data;
  Buffer.contents b

let recv_frame c =
  let h = exact c 2 in
  let a = Char.code h.[0] and b = Char.code h.[1] in
  require (a land 128 <> 0 && b land 128 = 0) "Server frame flags";
  let n = b land 127 in
  let n =
    if n = 126 || n = 127 then (
      let bytes = exact c (if n = 126 then 2 else 8) in
      let value = ref 0 in
      String.iter
        (fun c ->
          require (!value <= 1048576) "Frame length limit";
          value := (!value lsl 8) lor Char.code c)
        bytes;
      !value)
    else n
  in
  require (n <= 1048576) "Response frame bound";
  (a land 15, exact c n)

let exercise app =
  with_connection app.port (fun c ->
      let ids = ref [] in
      for _ = 1 to 10 do
        let r = request ~connection:c app "GET" "/health" in
        require (r.status = 200 && r.body = "ok\n") "Health";
        require
          (header "x-content-type-options" r = "nosniff")
          "Security header";
        ids := header "x-request-id" r :: !ids
      done;
      require
        (List.length (List.sort_uniq String.compare !ids) = 10)
        "Fresh request IDs";
      let r = request ~connection:c app "HEAD" "/health" in
      require
        (r.status = 200 && r.body = "" && header "content-length" r = "3")
        "HEAD fallback";
      List.iter
        (fun (meth, path, status) ->
          require ((request ~connection:c app meth path).status = status) path)
        [
          ("POST", "/health", 405);
          ("GET", "/missing", 404);
          ("GET", "/error", 500);
          ("GET", "/health", 200);
        ]);
  let json_headers = [ ("Content-Type", "application/json") ] in
  require
    ((request ~body:"{\"x\":1}" ~headers:json_headers app "POST" "/json").body
   = "{\"x\":1}")
    "JSON echo";
  List.iter
    (fun body ->
      require
        ((request ~body ~headers:json_headers app "POST" "/json").status = 400)
        "Malformed/deep JSON")
    [
      "{\"x\":1,\"x\":2}"; String.make 103 '[' ^ "0" ^ String.make 103 ']'; "{";
    ];
  require
    ((request ~body:"x=a%26b"
        ~headers:[ ("Content-Type", "application/x-www-form-urlencoded") ]
        app "POST" "/form")
       .body = "{\"x\":\"a&b\"}")
    "Form decoding";
  let body =
    "--x\r\n\
     Content-Disposition: form-data; name=\"file\"; filename=\"../../evil\"\r\n\
     \r\n\
     hello\r\n\
     --x--\r\n"
  in
  require
    ((request ~body
        ~headers:[ ("Content-Type", "multipart/form-data; boundary=x") ]
        app "POST" "/upload")
       .body = "5")
    "Multipart upload";
  let r = request app "GET" "/static/hello.txt" in
  require (r.status = 200 && r.body = "static contents\n") "Static file";
  require
    ((request
        ~headers:[ ("If-None-Match", header "etag" r) ]
        app "GET" "/static/hello.txt")
       .status = 304)
    "Static validator";
  List.iter
    (fun path ->
      let r = request app "GET" path in
      require
        (List.mem r.status [ 400; 404 ] && not (contains r.body "PRIVATE"))
        ("Static confinement: " ^ path))
    [
      "/static/%2e%2e/private.txt";
      "/static/escape.txt";
      "/static/.env";
      "/static/%2fetc/passwd";
    ];
  require
    ((request app "GET" "/stream").body = String.make 1048576 'x')
    "Stream payload";
  require ((request app "HEAD" "/stream").body = "") "HEAD skips producer";
  require
    ((request app "GET" "/events").body
   = "id: 1\ndata: event 1\n\nid: 2\ndata: event 2\n\nid: 3\ndata: event 3\n\n"
    )
    "SSE bytes";
  let r =
    request
      ~headers:
        [
          ("Origin", "https://app.example");
          ("Access-Control-Request-Method", "POST");
          ("Access-Control-Request-Headers", "content-type");
        ]
      app "OPTIONS" "/json"
  in
  require
    (r.status = 204
    && header "access-control-allow-origin" r = "https://app.example")
    "CORS preflight";
  require
    ((request
        ~headers:[ ("Origin", "https://evil.example") ]
        app "GET" "/health")
       .status = 403)
    "CORS denial";
  require
    ((request app "POST" "/login").status = 401)
    "No default authentication";
  let r =
    request
      ~headers:[ ("Authorization", "Bearer synthetic-test-token") ]
      app "POST" "/login"
  in
  require
    (r.status = 200
    && contains (header "set-cookie" r) "Secure"
    && contains (header "set-cookie" r) "HttpOnly")
    "Session cookie";
  let cookie = List.hd (String.split_on_char ';' (header "set-cookie" r)) in
  let r = request ~headers:[ ("Cookie", cookie) ] app "GET" "/session" in
  require (r.status = 200) "Session lookup";
  let csrf = string (field "csrf" (Yojson.Basic.from_string r.body)) in
  require
    ((request
        ~headers:[ ("Cookie", cookie ^ "; " ^ cookie) ]
        app "GET" "/session")
       .status = 401)
    "Ambiguous session";
  require
    ((request
        ~headers:[ ("Cookie", cookie); ("Origin", "https://app.example") ]
        app "POST" "/logout")
       .status = 403)
    "CSRF required";
  require
    ((request
        ~headers:
          [
            ("Cookie", cookie);
            ("Origin", "https://app.example");
            ("X-CSRF-Token", csrf);
          ]
        app "POST" "/logout")
       .status = 200)
    "Logout";
  require
    ((request ~headers:[ ("Cookie", cookie) ] app "GET" "/session").status = 401)
    "Revocation";
  with_connection app.port (fun c ->
      let key = Base64.encode_exn "0123456789abcdef" in
      send c
        ("GET /ws HTTP/1.1\r\n\
          Host: localhost\r\n\
          Upgrade: websocket\r\n\
          Connection: Upgrade\r\n\
          Sec-WebSocket-Version: 13\r\n\
          Sec-WebSocket-Key: " ^ key ^ "\r\nOrigin: https://app.example\r\n\r\n"
       ^ frame 1 "hello");
      let response = head c in
      require (starts ~prefix:"HTTP/1.1 101" response) "WebSocket upgrade";
      let expected =
        Base64.encode_exn
          Digestif.SHA1.(
            to_raw_string
              (digest_string (key ^ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
      in
      require (contains response expected) "WebSocket accept";
      require (recv_frame c = (1, "hello")) "Handoff suffix";
      String.iter
        (fun x -> send c (String.make 1 x))
        (frame ~fin:false 1 "fragment " ^ frame 9 "p" ^ frame 0 "complete");
      require (recv_frame c = (10, "p")) "WebSocket pong";
      require (recv_frame c = (1, "fragment complete")) "Fragmentation";
      send c (frame 8 "");
      require (recv_frame c = (8, "")) "WebSocket close");
  with_connection app.port (fun c ->
      send c
        "POST /missing HTTP/1.1\r\n\
         Host: localhost\r\n\
         Expect: 100-continue\r\n\
         Content-Length: 100\r\n\
         \r\n";
      require (starts ~prefix:"HTTP/1.1 404" (recv c 4096)) "Early rejection");
  print_endline
    "PASS framework HTTP, sessions/CSRF, static confinement, streaming, SSE \
     and WebSocket lifecycle"

let main args =
  let binary = option args "--binary" "" in
  if binary = "" then Build.call [ "build"; "examples/framework/server.exe" ];
  let binary =
    if binary = "" then Build.binary "examples/framework/server.exe"
    else absolute binary
  in
  let directory =
    temp_dir ~parent:(root / "_artifacts/framework") "integration-"
  in
  with_app ~binary ~directory exercise
