open Lwt.Infix
open Httpkit_core
module A = Httpkit_transport_lwt
module E = Httpkit_engine
module App = Httpkit_lwt

let check label b = if not b then failwith label
let run p = Lwt_main.run (Lwt_unix.with_timeout 10. (fun () -> p))

let () =
  Mirage_crypto_rng_unix.use_default ();
  run
    (let accepted = Lwt_mvar.create_empty () and stop, wake = Lwt.wait () in
     let produced = ref 0 and captured = ref None and logs = ref [] in
     let sessions =
       App.Sessions.create ~ttl:60. ~clock:A.monotonic_clock
         ~random:Mirage_crypto_rng.generate ()
     in
     let handler =
       App.routes
         ~middleware:
           [
             App.Common.security_headers;
             App.Common.access_log ~now:A.monotonic_clock.now (fun event ->
                 logs := event :: !logs);
             App.Common.cors ~origins:[ "https://app.example" ]
               ~methods:[ "GET"; "POST" ] ~headers:[ "x-csrf-token" ]
               ~credentials:true ();
           ]
         [
           App.route Method.get "/hello/:name" (fun r ->
               Lwt.return
                 (App.reply
                    (Httpkit.Reply.text (Option.get (App.param "name" r)))));
           App.route Method.post "/echo" (fun r ->
               App.body r >|= fun body -> App.reply (Httpkit.Reply.text body));
           App.route Method.get "/stream" (fun _ ->
               Lwt.return
                 (App.stream (fun write ->
                      incr produced;
                      write "one" >>= fun () ->
                      Lwt.pause () >>= fun () -> write "two")));
           App.route Method.get "/capture" (fun r ->
               captured := Some r;
               Lwt.return (App.reply (Httpkit.Reply.text "ok")));
           App.route Method.post "/json" (fun r ->
               App.json r >|= function
               | Ok value -> App.reply (Httpkit.Reply.json value)
               | Error _ -> App.reply (Httpkit.Reply.text ~status:400 "invalid"));
           App.route Method.post "/form" (fun r ->
               App.form r >|= function
               | Ok fields ->
                   App.reply
                     (Httpkit.Reply.text
                        (String.concat "," (List.map snd fields)))
               | Error _ -> App.reply (Httpkit.Reply.text ~status:400 "invalid"));
           App.route Method.get "/proxy" (fun r ->
               Lwt.return
                 (match
                    App.Common.proxy ~trusted_peer:(fun p -> p = "local") r
                  with
                 | Ok (Some info) ->
                     App.reply (Httpkit.Reply.text info.client_ip)
                 | Ok None -> App.reply (Httpkit.Reply.text "ignored")
                 | Error _ ->
                     App.reply (Httpkit.Reply.text ~status:400 "invalid")));
           App.route Method.get "/proxy-real" (fun r ->
               Lwt.return
                 (match
                    App.Common.proxy ~ip_header:Httpkit.Proxy.Real_ip
                      ~trusted_peer:(fun p -> p = "local")
                      r
                  with
                 | Ok (Some info) ->
                     App.reply (Httpkit.Reply.text info.client_ip)
                 | _ -> App.reply (Httpkit.Reply.text ~status:400 "invalid")));
           App.route Method.get "/csrf"
             (App.Sessions.require sessions (fun s _ ->
                  Lwt.return
                    (App.reply (Httpkit.Reply.text (Httpkit.Session.csrf s)))));
           App.route Method.post "/rotate"
             (App.Sessions.csrf sessions ~origins:[ "https://app.example" ]
                (fun r ->
                  App.Sessions.rotate sessions r "rotated"
                    (App.reply (Httpkit.Reply.text "ok"))));
           App.route Method.post "/logout"
             (App.Sessions.csrf sessions ~origins:[ "https://app.example" ]
                (fun r ->
                  App.Sessions.logout sessions r
                    (App.reply (Httpkit.Reply.text "ok"))));
           App.route Method.get "/login" (fun _ ->
               App.Sessions.login sessions "user"
                 (App.reply (Httpkit.Reply.text "logged in")));
           App.route Method.get "/private"
             (App.Sessions.require sessions (fun s _ ->
                  Lwt.return
                    (App.reply (Httpkit.Reply.text (Httpkit.Session.value s)))));
         ]
     in
     let server =
       App.serve ~max_connections:2 ~clock:A.monotonic_clock
         ~random:Mirage_crypto_rng.generate ~stop
         ~accept:(fun () -> Lwt_mvar.take accepted)
         ~on_error:(fun exn ->
           (match exn with
           | A.Error failure ->
               Printf.eprintf "server: %s\n%!" (A.failure_to_string failure)
           | exn -> Printf.eprintf "server: %s\n%!" (Printexc.to_string exn));
           Lwt.fail exn)
         handler
     in
     let a, b = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     Lwt.finalize
       (fun () ->
         Lwt_mvar.put accepted (A.of_fd a, "local") >>= fun () ->
         A.with_connection (A.of_fd b)
           (Result.get_ok (E.client ()))
           (fun c ->
             let request ?(headers = []) meth target payload =
               if Sys.getenv_opt "HTTPKIT_TEST_TRACE" = Some "1" then
                 Printf.eprintf "request %s %s\n%!" (Method.to_string meth)
                   target;
               let headers =
                 Result.get_ok
                   (Headers.of_list
                      ([
                         ("host", "localhost");
                         ( "content-length",
                           string_of_int (String.length payload) );
                       ]
                      @ headers))
               in
               let r =
                 Request.create ~meth
                   ~target:(Result.get_ok (Target.of_string target))
                   ~headers ()
               in
               A.submit_request c r >>= fun id ->
               A.send c id payload >>= fun () ->
               A.finish c id >>= fun () ->
               A.next_event c >>= function
               | E.Response (_, head) ->
                   A.collect_body c id >|= fun (body, _) -> (head, body)
               | _ -> Lwt.fail_with "missing response"
             in
             request Method.get "/hello/alice" "" >>= fun (head, body) ->
             check "route capture" (body = "alice");
             check "security headers"
               (Httpkit.Reply.header_values "x-frame-options"
                  (Response.headers head)
               = [ "DENY" ]);
             request Method.post "/echo" "payload" >>= fun (_, body) ->
             check "body" (body = "payload");
             request Method.head "/stream" "" >>= fun (_, body) ->
             check "HEAD skips producer" (body = "" && !produced = 0);
             request Method.get "/stream" "" >>= fun (_, body) ->
             check "stream" (body = "onetwo" && !produced = 1);
             request Method.get "/capture" "" >>= fun _ ->
             check "expired body"
               (try
                  ignore (App.read (Option.get !captured));
                  false
                with Invalid_argument _ -> true);
             request Method.get "/private" "" >>= fun (head, _) ->
             check "auth required" (Status.to_int (Response.status head) = 401);
             request Method.get "/login" "" >>= fun (head, _) ->
             let cookie =
               List.hd
                 (Httpkit.Reply.header_values "set-cookie"
                    (Response.headers head))
               |> String.split_on_char ';' |> List.hd
             in
             request ~headers:[ ("cookie", cookie) ] Method.get "/private" ""
             >>= fun (_, body) ->
             check "session login" (body = "user");
             let status head = Status.to_int (Response.status head) in
             let cookie_from head =
               List.hd
                 (Httpkit.Reply.header_values "set-cookie"
                    (Response.headers head))
               |> String.split_on_char ';' |> List.hd
             in
             request ~headers:[ ("cookie", cookie) ] Method.get "/csrf" ""
             >>= fun (_, csrf) ->
             request ~headers:[ ("cookie", cookie) ] Method.post "/rotate" ""
             >>= fun (head, _) ->
             check "CSRF denied" (status head = 403);
             request
               ~headers:
                 [
                   ("cookie", cookie);
                   ("origin", "https://app.example");
                   ("x-csrf-token", csrf);
                 ]
               Method.post "/rotate" ""
             >>= fun (head, _) ->
             check "session rotated" (status head = 200);
             let rotated = cookie_from head in
             request ~headers:[ ("cookie", cookie) ] Method.get "/private" ""
             >>= fun (head, _) ->
             check "old session rejected" (status head = 401);
             request ~headers:[ ("cookie", rotated) ] Method.get "/private" ""
             >>= fun (_, body) ->
             check "new session value" (body = "rotated");
             request ~headers:[ ("cookie", rotated) ] Method.get "/csrf" ""
             >>= fun (_, csrf) ->
             request
               ~headers:
                 [
                   ("cookie", rotated);
                   ("origin", "https://app.example");
                   ("x-csrf-token", csrf);
                 ]
               Method.post "/logout" ""
             >>= fun (head, _) ->
             check "session logout" (status head = 200);
             request ~headers:[ ("cookie", rotated) ] Method.get "/private" ""
             >>= fun (head, _) ->
             check "logged out session rejected" (status head = 401);
             request
               ~headers:
                 [
                   ("origin", "https://app.example");
                   ("access-control-request-method", "POST");
                   ("access-control-request-headers", "x-csrf-token");
                 ]
               Method.options "/echo" ""
             >>= fun (head, _) ->
             check "CORS preflight"
               (status head = 204
               && Httpkit.Reply.header_values "access-control-allow-credentials"
                    (Response.headers head)
                  = [ "true" ]);
             request
               ~headers:[ ("origin", "https://evil.example") ]
               Method.get "/stream" ""
             >>= fun (head, _) ->
             check "CORS origin denied" (status head = 403);
             request
               ~headers:
                 [
                   ("origin", "https://app.example");
                   ("access-control-request-method", "POST");
                   ("access-control-request-headers", "x-evil");
                 ]
               Method.options "/echo" ""
             >>= fun (head, _) ->
             check "CORS header denied" (status head = 403);
             request
               ~headers:
                 [
                   ("x-forwarded-proto", "https");
                   ("x-forwarded-for", "192.0.2.1");
                 ]
               Method.get "/proxy" ""
             >>= fun (_, body) ->
             check "trusted proxy" (body = "192.0.2.1");
             request
               ~headers:
                 [
                   ("x-forwarded-proto", "https");
                   ("x-forwarded-for", "192.0.2.1, 192.0.2.2");
                 ]
               Method.get "/proxy" ""
             >>= fun (head, _) ->
             check "proxy chain denied" (status head = 400);
             request
               ~headers:
                 [
                   ("x-forwarded-proto", "https");
                   ("x-forwarded-for", "192.0.2.1");
                   ("x-real-ip", "192.0.2.2");
                 ]
               Method.get "/proxy-real" ""
             >>= fun (_, body) ->
             check "explicit real-IP profile" (body = "192.0.2.2");

             request
               ~headers:[ ("content-type", "application/json") ]
               Method.post "/json" {|{"x":1}|}
             >>= fun (_, body) ->
             check "JSON body" (body = {|{"x":1}|});
             request Method.post "/json" "" >>= fun (head, _) ->
             check "JSON content type" (status head = 400);
             request
               ~headers:
                 [ ("content-type", "application/x-www-form-urlencoded") ]
               Method.post "/form" "a=hello+world"
             >>= fun (_, body) ->
             check "form body" (body = "hello world");
             request Method.post "/form" "" >>= fun (head, _) ->
             check "form content type" (status head = 400);
             request Method.get "/missing" "" >>= fun (head, _) ->
             check "404" (Status.to_int (Response.status head) = 404);
             request Method.post "/stream" "" >>= fun (head, _) ->
             check "405" (Status.to_int (Response.status head) = 405);
             Lwt.return_unit)
         >>= fun () ->
         Lwt.wakeup_later wake ();
         server >>= fun () ->
         check "access records" (List.length !logs = 28);
         Lwt.return_unit)
       (fun () ->
         Lwt.cancel server;
         Lwt.catch (fun () -> server) (fun _ -> Lwt.return_unit)));
  print_endline
    "PASS Lwt application HTTP, routing, sessions, streaming, HEAD and request \
     lifetime"

let () =
  run
    (let queue = Lwt_mvar.create_empty () in
     let stop, _ = Lwt.wait () in
     let entered, signal = Lwt.wait () in
     let cleaned = ref false and closed = ref 0 in
     let handler _ =
       Lwt.wakeup_later signal ();
       Lwt.finalize
         (fun () -> fst (Lwt.task ()))
         (fun () ->
           cleaned := true;
           Lwt.return_unit)
     in
     let server =
       App.serve ~max_connections:1 ~clock:A.monotonic_clock
         ~random:Mirage_crypto_rng.generate ~stop
         ~accept:(fun () -> Lwt_mvar.take queue)
         ~on_error:(fun _ -> Lwt.return_unit)
         handler
     in
     let a, b = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let transport = A.of_fd a in
     let transport =
       {
         transport with
         close =
           (fun () ->
             incr closed;
             transport.close ());
       }
     in
     Lwt.finalize
       (fun () ->
         Lwt_mvar.put queue (transport, "local") >>= fun () ->
         let request = "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n" in
         Lwt_unix.write_string b request 0 (String.length request) >>= fun _ ->
         entered >>= fun () ->
         Lwt.cancel server;
         Lwt.catch
           (fun () -> server)
           (function Lwt.Canceled -> Lwt.return_unit | e -> Lwt.fail e)
         >>= fun () ->
         check "cancelled handler joined" !cleaned;
         check "transport closed once" (!closed = 1);
         check "caller stop preserved" (Lwt.is_sleeping stop);
         Lwt.return_unit)
       (fun () ->
         Lwt.cancel server;
         Lwt_unix.close b));
  print_endline
    "PASS Lwt cancellation joins handlers and closes transport exactly once"

let () =
  run
    (let output = Buffer.create 128 in
     let masked op payload =
       let mask = "abcd" in
       String.init
         (6 + String.length payload)
         (fun i ->
           if i = 0 then Char.chr (128 lor op)
           else if i = 1 then Char.chr (128 lor String.length payload)
           else if i < 6 then mask.[i - 2]
           else
             Char.chr
               (Char.code payload.[i - 6] lxor Char.code mask.[(i - 6) mod 4]))
     in
     let transport : A.transport =
       {
         read = (fun _ _ _ -> Lwt.return 0);
         write =
           (fun data offset length ->
             let n = min length 3 in
             Buffer.add_substring output data offset n;
             Lwt.return n);
         close = (fun () -> Lwt.return_unit);
       }
     in
     let suffix = masked 1 "hello" ^ masked 9 "ping" ^ masked 8 "" in
     App.Realtime.websocket ~clock:A.monotonic_clock transport suffix
       (fun event -> Lwt.return_some event)
     >|= fun () ->
     let frame event = Result.get_ok (Httpkit.Websocket.encode event) in
     check "WebSocket echo ping and close"
       (Buffer.contents output
       = frame (Httpkit.Websocket.Text "hello")
         ^ frame (Httpkit.Websocket.Pong "ping")
         ^ frame (Httpkit.Websocket.Close (None, ""))));
  print_endline
    "PASS Lwt WebSocket partial writes, echo, ping and close handshake"
