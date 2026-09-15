open Httpkit_core
module App = Httpkit_eio
module W = Httpkit

let check label value = if not value then failwith label

let run ?(request_timeout = 0.1) handler client =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let server, peer = Eio_unix.Net.socketpair_stream ~sw () in
          let accepts = ref 0 and closes = ref 0 and errors = ref [] in
          let stop, notify = Eio.Promise.create () in
          let transport = Httpkit_transport_eio.of_flow server in
          let transport =
            {
              transport with
              close =
                (fun () ->
                  incr closes;
                  transport.close ());
            }
          in
          Eio.Fiber.both
            (fun () ->
              App.serve ~max_connections:1 ~request_timeout
                ~clock:(Eio.Stdenv.mono_clock env)
                ~random:(fun n -> String.make n 'x')
                ~stop
                ~accept:(fun () ->
                  incr accepts;
                  if !accepts = 1 then (transport, "127.0.0.1")
                  else Eio.Fiber.await_cancel ())
                ~on_error:(fun e -> errors := e :: !errors)
                handler)
            (fun () ->
              Fun.protect
                ~finally:(fun () -> Eio.Promise.resolve notify ())
                (fun () -> client env peer));
          check "single transport close" (!closes = 1);
          !errors))

let raw peer request =
  Eio.Flow.copy_string request peer;
  let b = Buffer.create 128 and bytes = Cstruct.create 1024 in
  let rec loop () =
    match Eio.Flow.single_read peer bytes with
    | n ->
        Buffer.add_string b (Cstruct.to_string ~len:n bytes);
        loop ()
    | exception End_of_file -> Buffer.contents b
  in
  loop ()

let () =
  let held = ref None in
  let errors =
    run
      (fun request ->
        held := Some request;
        App.reply (W.Reply.text "ok"))
      (fun _ peer ->
        let response =
          raw peer
            "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        in
        check "response" (String.ends_with ~suffix:"ok" response);
        check "expired body handle"
          (try
             ignore (App.read (Option.get !held));
             false
           with Invalid_argument _ -> true))
  in
  check "successful exchange" (errors = []);
  let errors =
    run
      (fun _ -> Eio.Fiber.await_cancel ())
      (fun _ peer ->
        check "handler deadline closes"
          (raw peer "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" = ""))
  in
  check "handler deadline reported" (errors <> []);
  let errors =
    run
      (fun _ ->
        App.stream (fun send ->
            send "prefix";
            Eio.Fiber.await_cancel ()))
      (fun _ peer ->
        let response = raw peer "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" in
        check "producer deadline closes incomplete body"
          (String.starts_with ~prefix:"HTTP/1.1 200" response
          && not (String.ends_with ~suffix:"0\r\n\r\n" response)))
  in
  check "producer deadline reported" (errors <> []);
  let errors =
    run
      (fun request ->
        check "untrusted forwarding ignored"
          (App.Common.proxy ~trusted_peer:(fun _ -> false) request = Ok None);
        check "trusted chain rejected"
          (Result.is_error
             (App.Common.proxy ~trusted_peer:(fun _ -> true) request));
        App.reply (W.Reply.text "ok"))
      (fun _ peer ->
        ignore
          (raw peer
             "GET / HTTP/1.1\r\n\
              Host: localhost\r\n\
              X-Forwarded-Proto: https\r\n\
              X-Forwarded-For: 1.2.3.4, 5.6.7.8\r\n\
              Connection: close\r\n\
              \r\n"))
  in
  check "proxy checks" (errors = []);
  let directory = Filename.temp_file "httpkit-uploads-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir directory)
    (fun () ->
      List.iter
        (fun fail_callback ->
          let endpoint = ref (fun _ -> assert false) in
          let seen = ref 0 in
          ignore
            (run
               (fun request -> !endpoint request)
               (fun env peer ->
                 (endpoint :=
                    fun request ->
                      let root = Eio.Path.(Eio.Stdenv.fs env / directory) in
                      App.Files.with_upload ~directory:root
                        ~random:(fun n -> String.make n 'z')
                        request ~boundary:"test"
                        (fun part basename ->
                          incr seen;
                          check "upload filename metadata"
                            (part.W.Multipart.filename = Some "../../escape");
                          check "generated basename"
                            (not (String.contains basename '/'));
                          check "upload exact bytes"
                            (Eio.Path.load Eio.Path.(root / basename)
                            = "contents");
                          if fail_callback then failwith "callback failed");
                      App.reply (W.Reply.text "uploaded"));
                 let body =
                   "--test\r\n\
                    Content-Disposition: form-data; name=\"f\"; \
                    filename=\"../../escape\"\r\n\
                    \r\n\
                    contents\r\n\
                    --test--\r\n"
                 in
                 let response =
                   raw peer
                     ("POST / HTTP/1.1\r\n\
                       Host: localhost\r\n\
                       Connection: close\r\n\
                       Content-Length: "
                     ^ string_of_int (String.length body)
                     ^ "\r\n\r\n" ^ body)
                 in
                 check "upload response"
                   (String.starts_with
                      ~prefix:
                        (if fail_callback then "HTTP/1.1 500"
                         else "HTTP/1.1 200")
                      response);
                 check "upload cleanup" (Sys.readdir directory = [||])));
          check "upload callback count" (!seen = 1))
        [ false; true ]);
  print_endline
    "PASS Eio request lifetime, deadlines, proxy trust, upload and transport \
     cleanup"

let () =
  let directory = Filename.temp_file "httpkit-upload-cancel-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir directory)
    (fun () ->
      let endpoint = ref (fun _ -> assert false) in
      let errors =
        run ~request_timeout:0.5
          (fun request -> !endpoint request)
          (fun env peer ->
            (endpoint :=
               fun request ->
                 App.Files.with_upload
                   ~directory:Eio.Path.(Eio.Stdenv.fs env / directory)
                   ~random:(fun n -> String.make n 'q')
                   request ~boundary:"x"
                   (fun _ _ -> ());
                 App.reply (W.Reply.text "unexpected"));
            Eio.Flow.copy_string
              "POST / HTTP/1.1\r\n\
               Host: localhost\r\n\
               Content-Length: 1000\r\n\
               \r\n\
               --x\r\n\
               Content-Disposition: form-data; name=x\r\n\
               \r\n\
               incomplete"
              peer;
            Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 0.02;
            check "upload created before cancellation"
              (Array.length (Sys.readdir directory) = 1);
            ignore (raw peer "");
            check "cancelled upload removed" (Sys.readdir directory = [||]))
      in
      check "upload cancellation reported" (errors <> []));
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let frame op data =
        String.make 1 (Char.chr (128 lor op))
        ^ String.make 1 (Char.chr (128 lor String.length data))
        ^ "abcd"
        ^ String.mapi
            (fun i c -> Char.chr (Char.code c lxor Char.code "abcd".[i mod 4]))
            data
      in
      let read_count = ref 0 and written = Buffer.create 32 in
      let incoming = ref (frame 8 "") in
      let transport : Httpkit_transport_eio.transport =
        {
          close = (fun () -> ());
          read =
            (fun b off len ->
              incr read_count;
              let n = min len (String.length !incoming) in
              Bytes.blit_string !incoming 0 b off n;
              incoming := String.sub !incoming n (String.length !incoming - n);
              n);
          write =
            (fun s off len ->
              let n = min 1 len in
              Buffer.add_substring written s off n;
              n);
        }
      in
      App.Realtime.websocket ~clock ~idle_timeout:0.1 transport
        (frame 1 "close") (fun _ -> Some (W.Websocket.Close (Some 1000, "bye")));
      check "server close awaits peer" (!read_count = 1);
      check "partial WebSocket writes"
        (Buffer.contents written
        = Result.get_ok
            (W.Websocket.encode (W.Websocket.Close (Some 1000, "bye"))));
      check "invalid WebSocket transport write"
        (try
           App.Realtime.websocket ~clock
             { transport with write = (fun _ _ _ -> 0) }
             (frame 9 "ping")
             (fun _ -> None);
           false
         with Failure _ -> true));
  print_endline
    "PASS interrupted upload cleanup and server-initiated WebSocket close \
     handshake"

let request_case ?(meth = "GET") ?(headers = "") ?(body = "") setup verify =
  let endpoint = ref (fun _ -> assert false) in
  let errors =
    run ~request_timeout:1.
      (fun request -> !endpoint request)
      (fun env peer ->
        endpoint := setup env;
        let response =
          raw peer
            (meth
           ^ " /item/value?secret=hidden HTTP/1.1\r\n\
              Host: localhost\r\n\
              Connection: close\r\n\
              Content-Length: "
            ^ string_of_int (String.length body)
            ^ "\r\n" ^ headers ^ "\r\n" ^ body)
        in
        verify response)
  in
  check "request case no errors" (errors = [])

let response_status status response =
  check "expected status"
    (String.starts_with ~prefix:("HTTP/1.1 " ^ string_of_int status) response)

let () =
  request_case
    (fun _ ->
      let captured = ref None in
      let logger =
        App.Common.access_log
          ~now:(fun () -> 5.)
          (fun record -> captured := Some record)
      in
      fun request ->
        let response =
          logger (fun _ -> App.reply (W.Reply.text "ok")) request
        in
        let record = Option.get !captured in
        check "logs omit query credentials"
          (record.path = "/item/value"
          && record.meth = "GET" && record.status = 200 && record.seconds = 0.
          && record.request_id = App.request_id request);
        response)
    (response_status 200);
  List.iter
    (fun (headers, valid) ->
      request_case ~headers
        (fun _ request ->
          check "proxy metadata validation"
            (Result.is_ok
               (App.Common.proxy ~trusted_peer:(fun _ -> true) request)
            = valid);
          App.reply (W.Reply.text "ok"))
        (response_status 200))
    [
      ("X-Forwarded-Proto: https\r\nX-Forwarded-For: 127.0.0.1\r\n", true);
      ("X-Forwarded-Proto: http\r\nX-Forwarded-For: ::1\r\n", true);
      ("X-Forwarded-Proto: https\r\nX-Forwarded-For: bad\r\n", false);
      ("Forwarded: for=127.0.0.1\r\n", false);
    ];
  request_case
    ~headers:
      "X-Forwarded-Proto: https\r\n\
       X-Forwarded-For: 192.0.2.1\r\n\
       X-Real-IP: 192.0.2.2\r\n"
    (fun _ request ->
      check "explicit real-IP profile"
        (App.Common.proxy ~ip_header:W.Proxy.Real_ip
           ~trusted_peer:(fun _ -> true)
           request
        = Ok (Some { W.Proxy.scheme = "https"; client_ip = "192.0.2.2" }));
      App.reply (W.Reply.text "ok"))
    (response_status 200);
  List.iter
    (fun (meth, headers, status) ->
      request_case ~meth ~headers
        (fun _ ->
          App.Common.cors ~origins:[ "https://app.example" ] ~methods:[ "GET" ]
            ~headers:[ "X-Test" ] () (fun _ ->
              App.reply (W.Reply.make ~headers:[ ("vary", "Origin") ] "ok")))
        (response_status status))
    [
      ("GET", "Origin: https://app.example\r\n", 200);
      ( "OPTIONS",
        "Origin: https://app.example\r\nAccess-Control-Request-Method: POST\r\n",
        403 );
      ( "OPTIONS",
        "Origin: https://app.example\r\n\
         Access-Control-Request-Method: GET\r\n\
         Access-Control-Request-Headers: evil\r\n",
        403 );
    ];
  request_case
    (fun _ request ->
      check "missing JSON content type" (Result.is_error (App.json request));
      check "missing form content type" (Result.is_error (App.form request));
      check "negative body limit"
        (try
           ignore (App.body ~limit:(-1) request);
           false
         with Invalid_argument _ -> true);
      App.routes
        [
          App.route Method.get "/item/:id" (fun r ->
              check "route params"
                (App.params r = [ ("id", "value") ]
                && App.param "id" r = Some "value");
              ignore (App.body r);
              check "body EOF repeat" (App.read r = None);
              App.reply (W.Reply.text "ok"));
        ]
        request)
    (response_status 200);
  request_case
    (fun _ request -> App.websocket ~allowed_origins:[] request (fun _ _ -> ()))
    (response_status 400);
  Eio_main.run (fun env ->
      let counter = ref 0 and fail = ref false in
      let random n =
        if !fail then raise Exit
        else (
          incr counter;
          String.make n (Char.chr !counter))
      in
      let store =
        App.Sessions.create ~capacity:1 ~ttl:60.
          ~clock:(Eio.Stdenv.mono_clock env)
          ~random ()
      in
      fail := true;
      check "entropy failure"
        (try
           ignore (App.Sessions.login store "a" (App.reply (W.Reply.text "ok")));
           false
         with Exit -> true);
      fail := false;
      check "session mutex recovers"
        (App.status
           (App.Sessions.login store "a" (App.reply (W.Reply.text "ok")))
        = 200);
      check "session capacity response"
        (App.status
           (App.Sessions.login store "b" (App.reply (W.Reply.text "ok")))
        = 503));
  request_case ~headers:"Cookie: malformed\r\n"
    (fun env request ->
      let store =
        App.Sessions.create ~ttl:60.
          ~clock:(Eio.Stdenv.mono_clock env)
          ~random:(fun n -> String.make n 'x')
          ()
      in
      check "invalid cookie anonymous" (App.Sessions.find store request = None);
      check "rotate requires login"
        (App.status
           (App.Sessions.rotate store request "a"
              (App.reply (W.Reply.text "ok")))
        = 401);
      App.Sessions.require store
        (fun _ _ -> App.reply (W.Reply.text "unexpected"))
        request)
    (response_status 401);
  print_endline
    "PASS middleware metadata, handler composition and session error recovery"

let () =
  let directory = Filename.temp_file "httpkit-static-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat directory name))
        (Sys.readdir directory);
      Unix.rmdir directory)
    (fun () ->
      List.iter
        (fun (extension, mime) ->
          let path = Filename.concat directory ("asset" ^ extension) in
          let out = open_out_bin path in
          output_string out "bytes";
          close_out out;
          request_case
            (fun env ->
              App.Files.static
                ~root:Eio.Path.(Eio.Stdenv.fs env / directory)
                ("/asset" ^ extension))
            (fun response ->
              response_status 200 response;
              check "MIME and exact bytes"
                (String.ends_with ~suffix:"bytes" response
                &&
                let needle = "content-type: " ^ mime in
                let lower = String.lowercase_ascii response in
                let rec contains i =
                  i + String.length needle <= String.length lower
                  && (String.sub lower i (String.length needle) = needle
                     || contains (i + 1))
                in
                contains 0)))
        [
          (".html", "text/html");
          (".css", "text/css");
          (".js", "text/javascript");
          (".json", "application/json");
          (".png", "image/png");
          (".jpg", "image/jpeg");
          (".gif", "image/gif");
          (".svg", "image/svg+xml");
          (".ico", "image/x-icon");
          (".pdf", "application/pdf");
          (".woff2", "font/woff2");
          (".bin", "application/octet-stream");
        ];
      List.iter
        (fun (meth, url, limit, status) ->
          request_case ~meth
            (fun env ->
              App.Files.static ~max_bytes:limit
                ~root:Eio.Path.(Eio.Stdenv.fs env / directory)
                url)
            (response_status status))
        [
          ("POST", "/asset.bin", 10, 405);
          ("GET", "/asset.bin", 1, 404);
          ("GET", "/missing", 10, 404);
          ("GET", "/.secret", 10, 404);
          ("GET", "/", 10, 404);
        ];
      Unix.mkfifo (Filename.concat directory "pipe") 0o600;
      Unix.symlink "asset.bin" (Filename.concat directory "inside-link");
      Unix.symlink "missing" (Filename.concat directory "dangling-link");
      let outside = Filename.temp_file "httpkit-static-outside-" "" in
      Fun.protect
        ~finally:(fun () -> Sys.remove outside)
        (fun () ->
          let out = open_out_bin outside in
          output_string out "private-file-contents";
          close_out out;
          Unix.symlink outside (Filename.concat directory "outside-link");
          let empty = Filename.concat directory "empty-directory" in
          Unix.mkdir empty 0o700;
          Fun.protect
            ~finally:(fun () -> Unix.rmdir empty)
            (fun () ->
              List.iter
                (fun (url, status) ->
                  request_case
                    (fun env ->
                      App.Files.static
                        ~root:Eio.Path.(Eio.Stdenv.fs env / directory)
                        url)
                    (fun response ->
                      response_status status response;
                      if status = 200 then
                        check "confined symlink exact contents"
                          (String.ends_with ~suffix:"bytes" response)))
                [
                  ("/inside-link", 200);
                  ("/outside-link", 404);
                  ("/dangling-link", 404);
                  ("/empty-directory", 404);
                  ("/pipe", 404);
                  ("/%00", 400);
                  ("/%2e%2e/asset.bin", 400);
                  ("/%2Fasset.bin", 400);
                  ("/%5Casset.bin", 400);
                ]));
      request_case ~meth:"HEAD"
        (fun env ->
          App.Files.static
            ~root:Eio.Path.(Eio.Stdenv.fs env / directory)
            "/asset.bin")
        (fun response ->
          response_status 200 response;
          check "static HEAD suppresses collected body"
            (String.ends_with ~suffix:"\r\n\r\n" response)));
  print_endline
    "PASS confined static files, symlinks, nonregular files, HEAD and path \
     limits"

let () =
  let directory = Filename.temp_file "httpkit-upload-scope-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir directory)
    (fun () ->
      let endpoint = ref (fun _ -> assert false) in
      let seen = ref [] and created = ref 0 and scope_ok = ref true in
      let errors =
        run ~request_timeout:1.
          (fun request -> !endpoint request)
          (fun env peer ->
            (endpoint :=
               fun request ->
                 let root = Eio.Path.(Eio.Stdenv.fs env / directory) in
                 App.Files.with_upload ~directory:root
                   ~random:(fun n ->
                     incr created;
                     String.make n (Char.chr (64 + !created)))
                   request ~boundary:"scope"
                   (fun _ basename ->
                     scope_ok :=
                       !scope_ok
                       && Array.to_list (Sys.readdir directory) = [ basename ];
                     check "completed upload readable during callback"
                       (Eio.Path.load Eio.Path.(root / basename) = "contents");
                     seen := basename :: !seen);
                 check "last upload retired before helper returns"
                   (Sys.readdir directory = [||]);
                 App.reply (W.Reply.text "ok"));
            let part =
              "--scope\r\n\
               Content-Disposition: form-data; name=f; filename=ignored\r\n\
               \r\n\
               contents\r\n"
            in
            let body = part ^ part ^ "--scope--\r\n" in
            let response =
              raw peer
                ("POST / HTTP/1.1\r\n\
                  Host: localhost\r\n\
                  Connection: close\r\n\
                  Content-Length: "
                ^ string_of_int (String.length body)
                ^ "\r\n\r\n" ^ body)
            in
            check "multipart callback scope response"
              (String.starts_with ~prefix:"HTTP/1.1 200" response);
            check "multipart scope cleanup" (Sys.readdir directory = [||]))
      in
      check "multipart callbacks" (List.length !seen = 2);
      check "completed upload retired before next callback" !scope_ok;
      check "multipart scope errors" (errors = []));
  print_endline "PASS temporary upload files live only through their callback"

(* Wrap real confined filesystem operations, injecting faults at the I/O
   boundary without changing the production helper's API. *)
let fault_directory ~write ~close:on_close ~unlink:on_unlink (directory, path) =
  let wrap_file (Eio.Resource.T (state, ops)) =
    let module Raw = (val Eio.Resource.get ops Eio.File.Pi.Write) in
    let module File = struct
      include Raw

      let copy state ~src =
        write ();
        Raw.copy state ~src

      let close state =
        Raw.close state;
        on_close ()
    end in
    Eio.Resource.T (state, Eio.File.Pi.rw (module File))
  in
  let rec wrap_directory :
      'a. ([> `Dir ] as 'a) Eio.Resource.t -> 'a Eio.Resource.t =
   fun (Eio.Resource.T (state, ops)) ->
    let module Raw = (val Eio.Resource.get ops Eio.Fs.Pi.Dir) in
    let module Dir = struct
      include Raw

      let open_out state ~sw ~append ~create path =
        wrap_file (Raw.open_out state ~sw ~append ~create path)

      let open_subtree state ~sw path =
        wrap_directory (Raw.open_subtree state ~sw path)

      let unlink state path =
        on_unlink ();
        Raw.unlink state path
    end in
    Eio.Resource.T
      ( state,
        Eio.Resource.handler
          (Eio.Resource.H (Eio.Fs.Pi.Dir, (module Dir))
          :: Eio.Resource.bindings ops) )
  in
  (wrap_directory directory, path)

let upload_wire body =
  "POST / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: "
  ^ string_of_int (String.length body)
  ^ "\r\n\r\n" ^ body

let upload_part =
  "--fault\r\nContent-Disposition: form-data; name=f\r\n\r\ncontents\r\n"

let () =
  List.iter
    (fun fault ->
      let directory = Filename.temp_file "httpkit-upload-fault-" "" in
      Sys.remove directory;
      Unix.mkdir directory 0o700;
      Fun.protect
        ~finally:(fun () -> Unix.rmdir directory)
        (fun () ->
          let endpoint = ref (fun _ -> assert false) in
          let callbacks = ref 0
          and writes = ref 0
          and closes = ref 0
          and unlinks = ref 0
          and failed = ref false in
          let errors =
            run ~request_timeout:1.
              (fun request -> !endpoint request)
              (fun env peer ->
                let root = Eio.Path.(Eio.Stdenv.fs env / directory) in
                let root =
                  fault_directory root
                    ~write:(fun () ->
                      incr writes;
                      if fault = `Write then
                        raise (Unix.Unix_error (Unix.ENOSPC, "write", "")))
                    ~close:(fun () ->
                      incr closes;
                      if fault = `Close then failwith "injected close")
                    ~unlink:(fun () ->
                      incr unlinks;
                      if fault = `Unlink && !unlinks = 1 then
                        failwith "injected unlink")
                in
                (endpoint :=
                   fun request ->
                     (try
                        App.Files.with_upload ~directory:root
                          ~random:(fun n -> String.make n 'f')
                          request ~boundary:"fault"
                          (fun _ _ -> incr callbacks)
                      with exn ->
                        failed := true;
                        raise exn);
                     App.reply (W.Reply.text "unexpected"));
                let response =
                  raw peer (upload_wire (upload_part ^ "--fault--\r\n"))
                in
                check "upload I/O failure yields 500"
                  (String.starts_with ~prefix:"HTTP/1.1 500" response);
                check "upload I/O fault removes temporary file"
                  (Sys.readdir directory = [||]))
          in
          check "upload I/O failure propagated" (!failed && errors <> []);
          check "upload write exercised" (!writes > 0);
          check "upload explicitly closed once" (!closes = 1);
          check "unlink retried after failure"
            (!unlinks = if fault = `Unlink then 2 else 1);
          check "incomplete file never delivered"
            (!callbacks = if fault = `Unlink then 1 else 0)))
    [ `Write; `Close; `Unlink ];
  print_endline "PASS upload write, close and retryable unlink fault cleanup"

let () =
  List.iter
    (fun fault ->
      let directory = Filename.temp_file "httpkit-upload-permanent-" "" in
      Sys.remove directory;
      Unix.mkdir directory 0o700;
      Fun.protect
        ~finally:(fun () ->
          Array.iter
            (fun name -> Sys.remove (Filename.concat directory name))
            (Sys.readdir directory);
          Unix.rmdir directory)
        (fun () ->
          let basename =
            Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
              (String.make 24 'f')
          in
          let filename = Filename.concat directory basename in
          if fault = `Collision then (
            let channel = open_out_bin filename in
            output_string channel "existing sentinel";
            close_out channel);
          let endpoint = ref (fun _ -> assert false) in
          let closes = ref 0 and unlinks = ref 0 and callbacks = ref 0 in
          let errors =
            run
              ~request_timeout:(if fault = `Cancelled then 0.02 else 1.)
              (fun request -> !endpoint request)
              (fun env peer ->
                let root =
                  fault_directory
                    Eio.Path.(Eio.Stdenv.fs env / directory)
                    ~write:(fun () ->
                      if fault = `Write then
                        raise (Unix.Unix_error (Unix.ENOSPC, "write", "")))
                    ~close:(fun () -> incr closes)
                    ~unlink:(fun () ->
                      incr unlinks;
                      failwith "persistent unlink failure")
                in
                (endpoint :=
                   fun request ->
                     App.Files.with_upload ~directory:root
                       ~random:(fun n -> String.make n 'f')
                       request ~boundary:"fault"
                       (fun _ _ ->
                         incr callbacks;
                         if fault = `Cancelled then Eio.Fiber.await_cancel ();
                         if fault = `Callback then failwith "callback failure");
                     App.reply (W.Reply.text "unexpected"));
                let response =
                  raw peer
                    (upload_wire (upload_part ^ upload_part ^ "--fault--\r\n"))
                in
                check "persistent upload failure is not success"
                  ((fault = `Cancelled && response = "")
                  || String.starts_with ~prefix:"HTTP/1.1 500" response);
                check "failed unlink does not claim removal"
                  (Sys.readdir directory = [| basename |]);
                if fault = `Collision then (
                  let channel = open_in_bin filename in
                  let contents =
                    really_input_string channel (in_channel_length channel)
                  in
                  close_in channel;
                  check "exclusive creation preserves prior file"
                    (contents = "existing sentinel")))
          in
          check "permanent upload failure reported" (errors <> []);
          check "temporary file explicitly closed before retirement failure"
            (!closes = if fault = `Collision then 0 else 1);
          check "cleanup retries bounded"
            (!unlinks
            = match fault with `Collision -> 0 | `Write -> 1 | _ -> 2);
          check "no next part callback after cleanup failure"
            (!callbacks = match fault with `Write | `Collision -> 0 | _ -> 1);
          let rec cleanup_error = function
            | Failure message -> message = "persistent unlink failure"
            | Fun.Finally_raised exn -> cleanup_error exn
            | Eio.Exn.Multiple errors ->
                List.exists (fun (exn, _) -> cleanup_error exn) errors
            | _ -> false
          in
          if fault <> `Collision then
            check "cleanup failure remains observable"
              (List.exists cleanup_error errors)))
    [ `Unlink; `Callback; `Cancelled; `Write; `Collision ];
  print_endline
    "PASS permanent upload cleanup failures and exclusive collision ownership"

let () =
  let directory = Filename.temp_file "httpkit-upload-finalizer-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir directory)
    (fun () ->
      let endpoint = ref (fun _ -> assert false) in
      let callbacks = ref 0 and completed = ref false in
      let cleaning, notify_cleaning = Eio.Promise.create ()
      and release, notify_release = Eio.Promise.create () in
      let errors =
        run ~request_timeout:0.05
          (fun request -> !endpoint request)
          (fun env peer ->
            (endpoint :=
               fun request ->
                 App.Files.with_upload
                   ~directory:Eio.Path.(Eio.Stdenv.fs env / directory)
                   ~random:(fun n -> String.make n 'g')
                   request ~boundary:"fault"
                   (fun _ _ ->
                     incr callbacks;
                     Fun.protect
                       ~finally:(fun () ->
                         Eio.Cancel.protect (fun () ->
                             Eio.Promise.resolve notify_cleaning ();
                             Eio.Promise.await release;
                             check
                               "upload exists until callback cleanup finishes"
                               (Array.length (Sys.readdir directory) = 1);
                             completed := true))
                       Eio.Fiber.await_cancel);
                 App.reply (W.Reply.text "unexpected"));
            Eio.Flow.copy_string
              (upload_wire (upload_part ^ upload_part ^ "--fault--\r\n"))
              peer;
            Eio.Promise.await cleaning;
            check "callback cleanup suspended" (not !completed);
            Eio.Promise.resolve notify_release ();
            ignore (raw peer "");
            check "callback cleanup joined before connection EOF" !completed;
            check "cancelled completed upload removed"
              (Sys.readdir directory = [||]))
      in
      check "cancelled callback never starts next part" (!callbacks = 1);
      check "cancelled callback error reported" (errors <> []));
  print_endline "PASS cancelled upload callback cleanup joined before unlink"
