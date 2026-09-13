(* Loopback application and observable acceptance subject. Send "stop" on stdin
   to stop admission, drain active exchanges and close all owned transports. *)
open Httpkit_core
module A = Httpkit_transport_eio
module E = Httpkit_engine
module R = Httpkit_router

let ok = Result.get_ok
let upload_limit = 1048576
let download_bytes = 2097152
let chunk = String.make 8192 'x'

let response status body =
  Response.create
    ~status:(ok (Status.of_int status))
    ~headers:
      (ok
         (Headers.of_list
            [ ("content-length", string_of_int (String.length body)) ]))
    body

let routes =
  ok
    (R.compile
       (List.map
          (fun (meth, path, endpoint) ->
            R.route ~meth (ok (R.pattern path)) endpoint)
          [
            (Method.get, "/health", `Health);
            (Method.get, "/download", `Download);
            (Method.post, "/upload", `Upload);
            (Method.get, "/stats", `Stats);
          ]))

let tagged request response =
  let tag next request =
    let response = next request in
    Response.with_headers
      (ok
         (Headers.add
            (ok (Header.of_strings "x-example" "personal-eio"))
            (Response.headers response)))
      response
  in
  Httpkit_middleware.Basic.chain [ tag ] (fun _ -> response) request

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let clock = Eio.Stdenv.mono_clock env in
          let socket =
            Eio.Net.listen ~sw ~backlog:32 (Eio.Stdenv.net env)
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr socket with
            | `Tcp (_, p) -> p
            | _ -> assert false
          in
          let opened = ref 0
          and closed = ref 0
          and peak = ref 0
          and requests = ref 0 in
          let expected_errors = ref 0 and unexpected_errors = ref 0 in
          let connections = ref [] and stopping = ref false in
          let stop, signal_stop = Eio.Promise.create () in
          let stats () =
            Gc.full_major ();
            let gc = Gc.stat () in
            Printf.sprintf
              "{\"opened\":%d,\"closed\":%d,\"active\":%d,\"peak_active\":%d,\"requests\":%d,\"expected_errors\":%d,\"unexpected_errors\":%d,\"live_words\":%d,\"heap_words\":%d}\n"
              !opened !closed (!opened - !closed) !peak !requests
              !expected_errors !unexpected_errors gc.live_words gc.heap_words
          in
          let rec on_error = function
            | Eio.Exn.Multiple errors ->
                List.iter (fun (exn, _) -> on_error exn) errors
            | A.Error (A.Timeout _ | A.Engine (E.Protocol _ | E.Resource_limit))
              ->
                incr expected_errors
            | A.Error (A.Transport (Eio.Io _)) -> incr expected_errors
            | exn ->
                incr unexpected_errors;
                prerr_endline
                  (match exn with
                  | A.Error failure -> A.failure_to_string failure
                  | _ -> Printexc.to_string exn)
          in
          let send c id request r =
            let r = tagged request r in
            A.respond c id r;
            if Request.meth request <> Method.head then
              A.send c id (Response.body r);
            A.finish c id
          in
          let handle c =
            connections := c :: !connections;
            Fun.protect
              ~finally:(fun () ->
                connections :=
                  List.filter (fun other -> other != c) !connections)
              (fun () ->
                let rec loop () =
                  match A.next_event c with
                  | E.Request (id, request) ->
                      incr requests;
                      (match
                         R.lookup routes ~meth:(Request.meth request)
                           ~target:(Request.target request)
                       with
                      | Ok (R.Matched matched) -> (
                          if
                            Headers.get_all
                              (ok (Header.Name.of_string "expect"))
                              (Request.headers request)
                            <> []
                          then
                            A.respond c id
                              (Response.create
                                 ~status:(ok (Status.of_int 100))
                                 ());
                          let total = ref 0 and checksum = ref 0 in
                          let rec consume () =
                            match A.next_event c with
                            | E.Data (owner, data) when E.equal_id owner id ->
                                if String.length data > upload_limit - !total
                                then raise (A.Error (A.Engine E.Resource_limit));
                                total := !total + String.length data;
                                String.iter
                                  (fun ch ->
                                    checksum :=
                                      (!checksum + Char.code ch) mod 65536)
                                  data;
                                consume ()
                            | E.Trailers (owner, _) when E.equal_id owner id ->
                                consume ()
                            | E.Complete owner when E.equal_id owner id -> ()
                            | _ -> failwith "unexpected upload event"
                          in
                          consume ();
                          match matched.value with
                          | `Health -> send c id request (response 200 "ok\n")
                          | `Stats ->
                              send c id request (response 200 (stats ()))
                          | `Upload ->
                              send c id request
                                (response 200
                                   (Printf.sprintf "%d %d\n" !total !checksum))
                          | `Download ->
                              let head =
                                Response.create ~status:Status.ok
                                  ~headers:
                                    (ok
                                       (Headers.of_list
                                          [ ("transfer-encoding", "chunked") ]))
                                  ""
                              in
                              A.respond c id (tagged request head);
                              for
                                _ = 1 to download_bytes / String.length chunk
                              do
                                A.send c id chunk
                              done;
                              A.finish c id)
                      | Ok R.Not_found ->
                          send c id request (response 404 "not found\n")
                      | Ok (R.Method_not_allowed methods) ->
                          let r = response 405 "method not allowed\n" in
                          let h =
                            ok
                              (Header.of_strings "allow"
                                 (String.concat ", "
                                    (List.map Method.to_string methods)))
                          in
                          send c id request
                            (Response.with_headers
                               (ok (Headers.add h (Response.headers r)))
                               r)
                      | Error _ ->
                          send c id request (response 400 "invalid target\n"));
                      loop ()
                  | E.Complete _ | E.Body_aborted _ -> loop ()
                  | E.Closed _ -> ()
                  | _ -> failwith "unexpected connection event"
                in
                loop ())
          in
          Eio.Fiber.fork ~sw (fun () ->
              let input =
                Eio.Buf_read.of_flow (Eio.Stdenv.stdin env) ~max_size:64
              in
              (try ignore (Eio.Buf_read.line input) with End_of_file -> ());
              stopping := true;
              Eio.Promise.resolve signal_stop ());
          Printf.printf "%d\n%!" port;
          Eio.Fiber.first
            (fun () ->
              A.serve_connections ~max_connections:16 ~output_limit:32768
                ~limits:
                  (ok (E.Codec.limits ~body:(Int64.of_int download_bytes) ()))
                ~clock
                ~accept:(fun () ->
                  if !stopping then Eio.Fiber.await_cancel ();
                  let flow, _ = Eio.Net.accept ~sw socket in
                  if !stopping then (
                    Eio.Flow.close flow;
                    Eio.Fiber.await_cancel ());
                  incr opened;
                  peak := max !peak (!opened - !closed);
                  let transport = A.of_flow flow in
                  {
                    transport with
                    close =
                      (fun () ->
                        transport.close ();
                        incr closed);
                  })
                ~on_error handle)
            (fun () ->
              Eio.Promise.await stop;
              Eio.Fiber.all
                (List.map
                   (fun c () -> try A.shutdown c with exn -> on_error exn)
                   !connections));
          if !opened <> !closed || !connections <> [] then
            failwith "connection cleanup imbalance";
          print_string (stats ());
          if !unexpected_errors <> 0 then
            failwith "unexpected connection failures"))
