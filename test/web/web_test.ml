open Httpkit

let check label value = if not value then failwith label

let bad f =
  try
    f ();
    false
  with Invalid_argument _ -> true

let () =
  check "duplicate queries preserved"
    (Url.pairs "a=1&a=2+b" = Ok [ ("a", "1"); ("a", "2 b") ]);
  check "duplicate scalar rejected"
    (Url.unique "a" [ ("a", "1"); ("a", "2") ] = Error Url.Duplicate);
  List.iter
    (fun s -> check ("bad escape " ^ s) (Result.is_error (Url.decode s)))
    [ "%"; "%x0"; "%00"; "%0d" ];
  List.iter
    (fun s -> check ("traversal " ^ s) (Result.is_error (Url.path_segments s)))
    [ "/../x"; "/%2e%2e/x"; "/%2fetc"; "/a%5cb" ];
  check "query cap" (Url.pairs ~max_fields:1 "a&b" = Error Url.Limit);
  check "JSON depth" (Json.parse ~max_depth:1 "[[0]]" = Error Json.Too_deep);
  check "JSON duplicates"
    (Json.parse "{\"a\":1,\"a\":2}" = Error Json.Duplicate_key);
  check "JSON string brackets"
    (Result.is_ok (Json.parse ~max_depth:1 "[\"[[[\"]"));
  check "HTML text"
    (Html.render (Html.text "<script>\"&") = "&lt;script&gt;&quot;&amp;");
  check "HTML injection"
    (bad (fun () -> ignore (Html.element ~attrs:[ ("onclick", "x") ] "div" [])));
  check "HTML URL"
    (bad (fun () ->
         ignore (Html.element ~attrs:[ ("href", "javascript:alert(1)") ] "a" [])));
  check "framing ownership"
    (bad (fun () ->
         ignore (Reply.make ~headers:[ ("content-length", "3") ] "x")));
  check "redirect external"
    (bad (fun () -> ignore (Reply.redirect "//evil.example")));
  let state = Random.State.make [| 413; 17 |] in
  for _ = 1 to 2000 do
    let s =
      String.init (Random.State.int state 128) (fun _ ->
          Char.chr (32 + Random.State.int state 95))
    in
    check "URL round trip" (Url.decode (Url.encode s) = Ok s)
  done;
  print_endline "PASS web boundaries and 2000 seeded URL round trips"

let () =
  check "cookie defaults"
    (Cookie.set "sid" "abc" = "sid=abc; Path=/; Secure; HttpOnly; SameSite=Lax");
  check "cookie duplicate"
    (Cookie.find "sid" [ ("sid", "a"); ("sid", "b") ] = Error "duplicate cookie");
  check "cookie prefix"
    (bad (fun () -> ignore (Cookie.set ~secure:false "__Host-id" "x")));
  check "cookie injection"
    (bad (fun () -> ignore (Cookie.set "id" "x; Path=/")));
  let time = ref 0. and entropy = ref 0 in
  let random n =
    incr entropy;
    String.make n (Char.chr !entropy)
  in
  let store =
    Session.create ~capacity:1 ~ttl:10. ~now:(fun () -> !time) ~random ()
  in
  let first = Result.get_ok (Session.issue store "alice") in
  check "session cap" (Result.is_error (Session.issue store "bob"));
  check "CSRF"
    (Session.check_csrf first (Session.csrf first)
    && not (Session.check_csrf first "bad"));
  let next = Result.get_ok (Session.rotate store first "alice") in
  check "session fixation" (Session.find store (Session.token first) = None);
  check "session rotation" (Session.find store (Session.token next) <> None);
  time := 10.;
  check "session expiry" (Session.count store = 0);
  check "SSE CRLF" (Sse.event "a\r\nb" = Ok "data: a\ndata: b\n\n");
  check "SSE injection" (Result.is_error (Sse.event ~id:"x\nevent:bad" "x"));
  let wire =
    "--test\r\n\
     Content-Disposition: form-data; name=\"f\"; filename=\"../../x\"\r\n\
     \r\n\
     abc\r\n\
     --testXpayload\r\n\
     --test--\r\n"
  in
  for chunk_size = 1 to String.length wire do
    let contents = Buffer.create 32 and began = ref 0 and ended = ref 0 in
    let parser =
      Multipart.create ~boundary:"test" (function
        | Multipart.Begin p ->
            incr began;
            check "filename metadata" (p.filename = Some "../../x")
        | Multipart.Data s -> Buffer.add_string contents s
        | Multipart.End -> incr ended)
    in
    let rec feed i =
      if i < String.length wire then (
        check "multipart feed"
          (Multipart.feed parser
             (String.sub wire i (min chunk_size (String.length wire - i)))
          = Ok ());
        check "multipart retained bound"
          (Multipart.retained_bytes parser <= 8195);
        feed (i + min chunk_size (String.length wire - i)))
    in
    feed 0;
    check "multipart finish" (Multipart.finish parser = Ok ());
    check "multipart split invariant"
      (!began = 1 && !ended = 1
      && Buffer.contents contents = "abc\r\n--testXpayload")
  done;
  let limited = Multipart.create ~max_part_bytes:2 ~boundary:"test" ignore in
  check "multipart quota" (Result.is_error (Multipart.feed limited wire));
  check "multipart terminal" (Result.is_error (Multipart.feed limited ""));
  let masked ?(fin = true) op s =
    String.make 1 (Char.chr ((if fin then 128 else 0) lor op))
    ^ String.make 1 (Char.chr (128 lor String.length s))
    ^ "abcd"
    ^ String.mapi
        (fun i c -> Char.chr (Char.code c lxor Char.code "abcd".[i mod 4]))
        s
  in
  let wire =
    masked ~fin:false 1 "hel" ^ masked 9 "ping" ^ masked 0 "lo" ^ masked 8 ""
  in
  for n = 1 to String.length wire do
    let parser = Websocket.server () and events = ref [] in
    let rec feed i =
      if i < String.length wire then (
        let count = min n (String.length wire - i) in
        events :=
          !events
          @ Result.get_ok (Websocket.feed parser (String.sub wire i count));
        feed (i + count))
    in
    feed 0;
    check "WebSocket split invariant"
      (!events
      = [
          Websocket.Ping "ping";
          Websocket.Text "hello";
          Websocket.Close (None, "");
        ]);
    check "WebSocket close" (Websocket.eof parser = Ok ())
  done;
  List.iter
    (fun wire ->
      let parser = Websocket.server () in
      check "WebSocket malformed" (Result.is_error (Websocket.feed parser wire));
      check "WebSocket terminal" (Result.is_error (Websocket.feed parser "")))
    [
      "\129\000";
      masked 0 "orphan";
      masked ~fin:false 9 "bad";
      masked 1 "\255";
      masked 8 "x";
    ];
  print_endline
    "PASS cookie/session controls and exhaustive chunk-size \
     multipart/WebSocket splits"

let () =
  let headers fields = Result.get_ok (Httpkit_core.Headers.of_list fields) in
  List.iter
    (fun raw -> check "strict JSON" (Result.is_error (Json.parse raw)))
    [
      "/*comment*/1";
      "//comment\n1";
      "NaN";
      "Infinity";
      "\"raw\nnewline\"";
      "\"\\uDC00\"";
      "\"\255\"";
      "(1,2)";
    ];
  check "JSON limits"
    (Json.parse ~max_bytes:0 "1" = Error Json.Too_large
    && Json.parse ~max_depth:(-1) "0" = Error Json.Too_deep);
  List.iter
    (fun raw -> check "JSON scalar" (Result.is_ok (Json.parse raw)))
    [
      "true";
      "false";
      "null";
      "1.25";
      "-1";
      "\"\\uD83D\\uDE00\"";
      "{\"a\":{\"b\":[1]}}";
    ];
  check "multiline form"
    (Url.pairs "body=one%0Atwo%09three" = Ok [ ("body", "one\ntwo\tthree") ]);
  check "query absent" (Url.query "/path" = Ok []);
  check "query parsed" (Url.query "/?x=a+b" = Ok [ ("x", "a b") ]);
  check "unique absent" (Url.unique "x" [] = Ok None);
  check "unique present" (Url.unique "x" [ ("x", "v") ] = Ok (Some "v"));
  List.iter
    (fun s -> check "path errors" (Result.is_error (Url.path_segments s)))
    [ ""; "a"; "/?q"; "/#f"; "/%GG"; "/a\\b" ];
  check "path positive" (Url.path_segments "/a/%62" = Ok [ "a"; "b" ]);
  check "path cap" (Url.path_segments ~max_bytes:1 "/abc" = Error Url.Limit);
  check "decode cap" (Url.decode ~max_bytes:(-1) "" = Error Url.Limit);
  check "pair caps"
    (Url.pairs ~max_bytes:1 "ab" = Error Url.Limit
    && Url.pairs "x=%GG" = Error Url.Invalid_escape);
  List.iter
    (fun raw -> check "cookie errors" (Result.is_error (Cookie.parse [ raw ])))
    [ "missing"; "a=has space"; "=x"; "a=\000"; "a=x;b" ];
  check "cookie quoted"
    (Cookie.parse [ "a=\"value\"; b=2" ] = Ok [ ("a", "value"); ("b", "2") ]);
  check "cookie caps"
    (Result.is_error (Cookie.parse ~max_cookies:0 [ "a=b" ])
    && Result.is_error (Cookie.parse ~max_bytes:0 [ "a=b" ]));
  check "cookie missing" (Cookie.find "x" [] = Ok None);
  check "cookie one" (Cookie.find "x" [ ("x", "v") ] = Ok (Some "v"));
  List.iter
    (fun f -> check "cookie constructor rejects" (bad f))
    [
      (fun () ->
        ignore (Cookie.set ~same_site:Cookie.None_ ~secure:false "a" "b"));
      (fun () -> ignore (Cookie.set ~path:"/elsewhere" "__Host-id" "b"));
      (fun () -> ignore (Cookie.set ~path:"relative" "a" "b"));
      (fun () -> ignore (Cookie.set ~path:"/;x" "a" "b"));
      (fun () -> ignore (Cookie.set ~max_age:(-1) "a" "b"));
    ];
  ignore
    (Cookie.set ~secure:false ~http_only:false ~same_site:Cookie.Strict
       ~max_age:0 "a" "b");
  ignore (Cookie.set ~same_site:Cookie.None_ "a" "b");
  check "bearer absent" (Auth.bearer (headers []) = Ok None);
  check "bearer present"
    (Auth.bearer (headers [ ("authorization", "bEaReR abc") ]) = Ok (Some "abc"));
  List.iter
    (fun fields ->
      check "bearer rejected" (Result.is_error (Auth.bearer (headers fields))))
    [
      [ ("authorization", "Basic x") ];
      [ ("authorization", "Bearer") ];
      [ ("authorization", "Bearer a b") ];
      [ ("authorization", "Bearer a"); ("authorization", "Bearer b") ];
    ];
  check "authenticate callback"
    (Auth.authenticate
       ~verify:(fun s -> Some (String.length s))
       (headers [ ("authorization", "Bearer abc") ])
    = Ok (Some 3));
  ignore (Auth.authenticate ~verify:(fun _ -> None) (headers []));
  ignore
    (Auth.authenticate
       ~verify:(fun _ -> None)
       (headers [ ("authorization", "Basic x") ]));
  check "csrf safe"
    (Auth.csrf ~allowed_origins:[]
       ~token_valid:(fun _ -> false)
       ~meth:Httpkit_core.Method.head (headers []));
  check "csrf valid"
    (Auth.csrf ~allowed_origins:[ "https://a" ] ~token_valid:(( = ) "token")
       ~meth:Httpkit_core.Method.post
       (headers [ ("origin", "https://a"); ("x-csrf-token", "token") ]));
  check "HTML attrs"
    (Html.render
       (Html.element
          ~attrs:
            [
              ("href", "https://example.com/?a=1&b=2");
              ("title", "a'b");
              ("data-test", "x");
            ]
          "a"
          [ Html.text "link" ])
    = "<a href=\"https://example.com/?a=1&amp;b=2\" title=\"a&#39;b\" \
       data-test=\"x\">link</a>");
  List.iter
    (fun f -> check "HTML invalid" (bad f))
    [
      (fun () -> ignore (Html.element "script" []));
      (fun () -> ignore (Html.element ~attrs:[ ("src", "\\evil") ] "img" []));
      (fun () ->
        ignore (Html.element ~attrs:[ ("id", "a"); ("id", "b") ] "div" []));
      (fun () -> ignore (Html.element "br" [ Html.text "x" ]));
    ];
  ignore (Html.element ~attrs:[ ("href", "mailto:a@example.com") ] "a" []);
  ignore (Html.element ~attrs:[ ("href", "http://example.com") ] "a" []);
  check "void HTML" (Html.render (Html.element "br" []) = "<br>");
  List.iter
    (fun f -> check "reply rejects" (bad f))
    [
      (fun () -> ignore (Reply.make ~status:199 ""));
      (fun () -> ignore (Reply.make ~status:204 "x"));
      (fun () -> ignore (Reply.redirect ~status:200 "/"));
      (fun () -> ignore (Reply.redirect ""));
      (fun () -> ignore (Reply.redirect "/\\x"));
    ];
  ignore (Reply.make ~status:304 "");
  ignore (Reply.make ~status:204 "");
  ignore (Reply.redirect "/safe");
  ignore (Reply.html "ok");
  ignore (Reply.json (`List [ `Int 1 ]));
  let replaced =
    Reply.text "x"
    |> Reply.set_header "x-test" "one"
    |> Reply.set_header "X-Test" "two"
  in
  check "replace one header"
    (Reply.header_values "x-test" (Httpkit_core.Response.headers replaced)
    = [ "two" ]);
  check "SSE options"
    (Sse.event ~event:"update" ~retry:100 ""
    = Ok "event: update\nretry: 100\ndata: \n\n");
  check "SSE comment"
    (Sse.comment "hello" = Ok ": hello\n\n"
    && Result.is_error (Sse.comment "bad\n"));
  check "SSE rejects"
    (Result.is_error (Sse.event ~retry:(-1) "")
    && Result.is_error (Sse.event ~max_bytes:0 "x")
    && Result.is_error (Sse.event "\255"));
  print_endline "PASS strict parsing, browser metadata and response edge cases"

let () =
  let now = ref 0. in
  let const n = String.make n 'a' in
  List.iter
    (fun f -> check "session configuration" (bad f))
    [
      (fun () ->
        ignore
          (Session.create ~capacity:0 ~ttl:1.
             ~now:(fun () -> 0.)
             ~random:const ()));
      (fun () ->
        ignore
          (Session.create ~ttl:Float.nan ~now:(fun () -> 0.) ~random:const ()));
    ];
  let store = Session.create ~ttl:1. ~now:(fun () -> !now) ~random:const () in
  let first = Result.get_ok (Session.issue store ()) in
  check "issuance collision" (Result.is_error (Session.issue store ()));
  check "rotation collision" (Result.is_error (Session.rotate store first ()));
  check "rotation collision preserves session"
    (Session.find store (Session.token first) <> None);
  check "session token length" (Session.find store "short" = None);
  let foreign = Session.create ~ttl:1. ~now:(fun () -> !now) ~random:const () in
  ignore (Session.issue foreign ());
  check "foreign session" (Result.is_error (Session.rotate foreign first ()));
  now := 2.;
  check "rotate expired" (Result.is_error (Session.rotate store first ()));
  now := Float.nan;
  check "clock invalid" (bad (fun () -> ignore (Session.count store)));
  let broken =
    Session.create ~ttl:1. ~now:(fun () -> 0.) ~random:(fun _ -> "") ()
  in
  check "bad entropy" (bad (fun () -> ignore (Session.issue broken ())));
  let calls = ref 0 in
  let fail_random n =
    incr calls;
    if !calls > 2 then failwith "random failed"
    else String.make n (Char.chr !calls)
  in
  let s = Session.create ~ttl:1. ~now:(fun () -> 0.) ~random:fail_random () in
  let issued = Result.get_ok (Session.issue s ()) in
  check "entropy exception"
    (try
       ignore (Session.rotate s issued ());
       false
     with Failure _ -> true);
  check "entropy rollback" (Session.find s (Session.token issued) <> None);
  print_endline "PASS session expiry, collision and failure recovery"

let () =
  check "multipart boundary"
    (Multipart.boundary "multipart/form-data; boundary=abc" = Ok "abc");
  List.iter
    (fun s ->
      check "multipart boundary reject" (Result.is_error (Multipart.boundary s)))
    [
      "text/plain";
      "multipart/form-data; boundary=a; boundary=b";
      "multipart/form-data; boundary";
      "multipart/form-data; boundary=\"a\\b\"";
      "multipart/form-data; boundary=\"\"";
      "multipart/form-data; boundary=a b";
    ];
  check "multipart config"
    (bad (fun () -> ignore (Multipart.create ~boundary:"bad boundary" ignore)));
  check "multipart negative limit"
    (bad (fun () ->
         ignore (Multipart.create ~max_parts:(-1) ~boundary:"x" ignore)));
  let reject ?(max_header_bytes = 8192) ?(max_parts = 100)
      ?(max_total_bytes = 8388608) wire =
    let p =
      Multipart.create ~max_header_bytes ~max_parts ~max_total_bytes
        ~boundary:"x" ignore
    in
    let r = Multipart.feed p wire in
    check "multipart malformed"
      (Result.is_error r || Result.is_error (Multipart.finish p))
  in
  List.iter reject
    [
      "";
      "bad initial";
      "--xZZ";
      "--x\r\ninvalid\r\n\r\nx\r\n--x--";
      "--x\r\nContent-Disposition: attachment; name=x\r\n\r\nx\r\n--x--";
      "--x\r\nContent-Disposition: form-data\r\n\r\nx\r\n--x--";
      "--x\r\n\
       Content-Disposition: form-data; name=x\r\n\
       Content-Transfer-Encoding: base64\r\n\
       \r\n\
       x\r\n\
       --x--";
      "--x\r\nContent-Disposition: form-data; name=x\r\n\r\nunclosed";
      "--x--bad";
      "--x--\r";
      "--x--\r\nextra";
    ];
  reject ~max_header_bytes:1 "--x\r\nlong header";
  reject ~max_parts:0
    "--x\r\nContent-Disposition: form-data; name=x\r\n\r\nx\r\n--x--";
  reject ~max_total_bytes:1 "--x--";
  let p = Multipart.create ~boundary:"x" ignore in
  check "multipart empty"
    (Multipart.feed p "--x--" = Ok () && Multipart.finish p = Ok ());
  check "multipart after done" (Result.is_error (Multipart.feed p "extra"));
  let p = Multipart.create ~boundary:"x" (fun _ -> raise Exit) in
  check "multipart callback exception"
    (try
       ignore
         (Multipart.feed p
            "--x\r\nContent-Disposition: form-data; name=x\r\n\r\n");
       false
     with Exit -> true);
  check "multipart callback terminal" (Result.is_error (Multipart.finish p));
  print_endline
    "PASS multipart limits, metadata ambiguity and terminal failures"

let () =
  let mask s =
    String.mapi
      (fun i c -> Char.chr (Char.code c lxor Char.code "abcd".[i mod 4]))
      s
  in
  let frame ?(fin = true) op payload =
    let n = String.length payload in
    let h = String.make 1 (Char.chr ((if fin then 128 else 0) lor op)) in
    let length =
      if n < 126 then String.make 1 (Char.chr (128 lor n))
      else if n <= 65535 then
        "\254"
        ^ String.init 2 (function
          | 0 -> Char.chr (n lsr 8)
          | _ -> Char.chr (n land 255))
      else
        "\255"
        ^ String.init 8 (fun i ->
            Char.chr
              (Int64.to_int
                 (Int64.logand
                    (Int64.shift_right_logical (Int64.of_int n) ((7 - i) * 8))
                    255L)))
    in
    h ^ length ^ "abcd" ^ mask payload
  in
  List.iter
    (fun n ->
      let payload = String.make n 'x' and p = Websocket.server () in
      let wire = frame 2 payload in
      let rec loop i acc =
        if i = String.length wire then acc
        else
          let count = min 8192 (String.length wire - i) in
          loop (i + count)
            (acc @ Result.get_ok (Websocket.feed p (String.sub wire i count)))
      in
      check "WebSocket extended lengths"
        (loop 0 [] = [ Websocket.Binary payload ]);
      check "WebSocket encode length"
        (Result.is_ok (Websocket.encode (Websocket.Binary payload))))
    [ 0; 125; 126; 65535; 65536 ];
  List.iter
    (fun wire ->
      check "WebSocket malformed length or close"
        (Result.is_error (Websocket.feed (Websocket.server ()) wire)))
    [
      "\130\254\000\001";
      "\130\255\000\000\000\000\000\000\000\001";
      "\130\255\128\000\000\000\000\000\000\000";
      frame 8 "\003\237";
      frame 8 "\003\232\255";
      frame 9 (String.make 126 'x');
      frame ~fin:false 1 "a" ^ frame 2 "b";
      frame 8 "" ^ "x";
    ];
  check "WebSocket frame cap"
    (Result.is_error
       (Websocket.feed (Websocket.server ~max_frame:1 ()) (frame 2 "xx")));
  check "WebSocket message cap"
    (Result.is_error
       (Websocket.feed
          (Websocket.server ~max_message:1 ())
          (frame ~fin:false 2 "a" ^ frame 0 "b")));
  check "WebSocket chunk cap"
    (Result.is_error
       (Websocket.feed (Websocket.server ()) (String.make 65537 'x')));
  check "WebSocket config"
    (bad (fun () -> ignore (Websocket.server ~max_frame:(-1) ())));
  List.iter
    (fun event ->
      check "WebSocket encode reject" (Result.is_error (Websocket.encode event)))
    [
      Websocket.Text "\255";
      Websocket.Close (None, "reason");
      Websocket.Close (Some 1005, "");
      Websocket.Ping (String.make 126 'x');
    ];
  ignore (Websocket.encode (Websocket.Text "text"));
  ignore (Websocket.encode (Websocket.Ping "ping"));
  ignore (Websocket.encode (Websocket.Pong "pong"));
  ignore (Websocket.encode (Websocket.Close (Some 1000, "bye")));
  let p = Websocket.server () in
  check "abnormal EOF" (Result.is_error (Websocket.eof p));
  let headers =
    Result.get_ok
      (Httpkit_core.Headers.of_list
         [
           ("host", "localhost");
           ("connection", "upgrade");
           ("upgrade", "websocket");
           ("sec-websocket-version", "13");
           ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==");
           ("origin", "https://app.example");
         ])
  in
  let request =
    Httpkit_core.Request.create ~meth:Httpkit_core.Method.get
      ~target:(Result.get_ok (Httpkit_core.Target.of_string "/"))
      ~headers ()
  in
  let response =
    Result.get_ok
      (Websocket.handshake ~allowed_origins:[ "https://app.example" ] request)
  in
  check "RFC handshake"
    (Reply.header_values "sec-websocket-accept"
       (Httpkit_core.Response.headers response)
    = [ "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" ]);
  check "WebSocket origin"
    (Result.is_error (Websocket.handshake ~allowed_origins:[] request));
  print_endline
    "PASS RFC WebSocket handshake, lengths, fragmentation, UTF-8 and control \
     frames"

let () =
  check "SSE invalid UTF8 metadata"
    (Result.is_error (Sse.event ~id:"\255" "data"));
  check "SSE invalid UTF8 comment" (Result.is_error (Sse.comment "\255"));
  let p = Multipart.create ~boundary:"x" ignore in
  check "multipart rejects bare LF"
    (Result.is_error
       (Multipart.feed p
          "--x\r\n\
           Content-Disposition: form-data; name=x\n\
           X-Test: x\r\n\
           \r\n\
           y\r\n\
           --x--"));
  let ws = Websocket.server () in
  check "abnormal EOF" (Result.is_error (Websocket.eof ws));
  check "EOF failure is terminal" (Result.is_error (Websocket.feed ws ""))
