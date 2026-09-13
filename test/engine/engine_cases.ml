open Httpkit_core
open Httpkit_engine

let check b s = if not b then failwith s
let ok = function Ok x -> x | Error e -> failwith (error_to_string e)

let accepted = function
  | Accepted x -> x
  | Backpressured -> failwith "unexpected backpressure"

let value = function
  | Ok x -> x
  | Error e -> failwith (Httpkit_core.Error.to_string e)

let request ?(meth = Method.get) ?(target = "/") fields =
  Request.create ~meth
    ~target:(value (Target.of_string target))
    ~headers:(value (Headers.of_list fields))
    ()

let response status fields =
  Response.create
    ~status:(value (Status.of_int status))
    ~headers:(value (Headers.of_list fields))
    ()

let get = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
let post = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n"
let offered t s = offer t s ~off:0 ~len:(String.length s)
let feed t s = ok (offer t s ~off:0 ~len:(String.length s))

let request_id t =
  match poll_event t with
  | Some (Request (id, _)) -> id
  | _ -> failwith "missing request"

let complete t id =
  match poll_event t with
  | Some (Complete id') -> check (equal_id id id') "wrong completion id"
  | _ -> failwith "missing complete"

let drain ?(step = max_int) t =
  let b = Buffer.create 128 in
  let rec loop count =
    if count > 100000 then failwith "unbounded output"
    else
      match output t with
      | None -> Buffer.contents b
      | Some (bytes, off, len) ->
          let again = output t in
          check (again = Some (bytes, off, len)) "unstable output";
          let n = min step len in
          Buffer.add_substring b bytes off n;
          ignore (ok (acknowledge t n));
          loop (count + 1)
  in
  loop 0

let server_request wire =
  let t = ok (server ()) in
  ignore (feed t wire);
  let id = request_id t in
  (t, id)

let reply t id =
  ignore
    (accepted (ok (respond t id (response 200 [ ("content-length", "3") ]))));
  ignore (accepted (ok (send_data t id "abc")));
  ignore (accepted (ok (finish t id)))

let protocol_cases =
  [
    ( "engine/server/pipeline",
      fun () ->
        let t = ok (server ()) in
        check (feed t (get ^ get) = String.length get) "pipeline overconsume";
        let id = request_id t in
        complete t id;
        check (feed t get = 0) "second request admitted before response";
        reply t id;
        check
          (drain ~step:1 t = "HTTP/1.1 200 \r\ncontent-length: 3\r\n\r\nabc")
          "partial write mismatch";
        check (feed t get = String.length get) "pipeline not resumed";
        let id2 = request_id t in
        check (id_number id2 = Int64.succ (id_number id)) "id sequence";
        check (send_data t id "x" = Error Invalid_command) "stale id accepted"
    );
    ( "engine/input/backpressure",
      fun () ->
        let t = ok (server ()) in
        check (feed t (post ^ "abc") = String.length post) "head overconsume";
        check (feed t "abc" = 0) "head event not backpressured";
        let id = request_id t in
        check (feed t "abcNEXT" = 3) "body overconsume";
        check (queued_input_bytes t = 3) "missing retained accounting";
        check (feed t get = 0) "body event not backpressured";
        (match poll_event t with
        | Some (Data (id', "abc")) -> check (equal_id id id') "data id"
        | _ -> failwith "body data");
        complete t id;
        check (queued_input_bytes t = 0) "retained consumed data" );
    ( "engine/output/backpressure",
      fun () ->
        let t = ok (server ~output_limit:64 ()) in
        ignore (feed t get);
        let id = request_id t in
        complete t id;
        ignore
          (accepted
             (ok (respond t id (response 200 [ ("content-length", "3") ]))));
        check (ok (send_data t id "abc") = Backpressured) "output limit ignored";
        let prefix = drain t in
        ignore (accepted (ok (send_data t id "abc")));
        ignore (accepted (ok (finish t id)));
        check
          (prefix ^ drain t = "HTTP/1.1 200 \r\ncontent-length: 3\r\n\r\nabc")
          "retry duplication" );
    ( "engine/ids/ownership",
      fun () ->
        let a, ia = server_request get and b, ib = server_request get in
        check
          (id_number ia = id_number ib && not (equal_id ia ib))
          "cross-connection identity";
        check
          (respond a ib (response 200 [ ("content-length", "0") ])
          = Error Invalid_command)
          "foreign id accepted";
        check
          (respond b ia (response 200 [ ("content-length", "0") ])
          = Error Invalid_command)
          "foreign id accepted" );
    ( "engine/server/early-final",
      fun () ->
        let t, id = server_request post in
        ignore
          (accepted
             (ok (respond t id (response 413 [ ("content-length", "0") ]))));
        (match poll_event t with
        | Some (Body_aborted id') -> check (equal_id id id') "aborted id"
        | _ -> failwith "body abandonment hidden");
        ignore (accepted (ok (finish t id)));
        ignore (drain t);
        check (poll_event t = Some (Closed None)) "early response reused";
        check
          (Result.is_error (offer t get ~off:0 ~len:(String.length get)))
          "unread body reused" );
    ( "engine/server/discard",
      fun () ->
        let t, id = server_request post in
        ignore (ok (discard_body t id));
        check (feed t "abcNEXT" = 3) "discard overconsume";
        complete t id;
        reply t id;
        ignore (drain t);
        check (feed t get = String.length get) "discard prevented safe reuse" );
    ( "engine/server/informational",
      fun () ->
        let t, id = server_request post in
        ignore (accepted (ok (respond t id (response 100 []))));
        check (drain t = "HTTP/1.1 100 \r\n\r\n") "informational bytes";
        ignore (feed t "abc");
        ignore (poll_event t);
        complete t id;
        reply t id;
        ignore (drain t) );
    ( "engine/client/response",
      fun () ->
        let t = ok (client ()) in
        let id = accepted (ok (submit_request t (request [ ("host", "x") ]))) in
        ignore (accepted (ok (finish t id)));
        check
          (drain ~step:1 t = "GET / HTTP/1.1\r\nhost: x\r\n\r\n")
          "canonical request";
        let wire = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcNEXT" in
        let n = feed t wire in
        (match poll_event t with
        | Some (Response (id', _)) -> check (equal_id id id') "response id"
        | _ -> failwith "missing response");
        check
          (feed t (String.sub wire n (String.length wire - n)) = 3)
          "response overconsume";
        check (poll_event t = Some (Data (id, "abc"))) "client data";
        complete t id );
    ( "engine/client/expect",
      fun () ->
        let t = ok (client ()) in
        let id =
          accepted
            (ok
               (submit_request t
                  (request ~meth:Method.post
                     [
                       ("host", "x");
                       ("content-length", "3");
                       ("expect", "100-continue");
                     ])))
        in
        ignore (drain t);
        check (ok (send_data t id "abc") = Backpressured) "body before continue";
        ignore (feed t "HTTP/1.1 100 Continue\r\n\r\n");
        (match poll_event t with
        | Some (Informational (id', r)) ->
            check
              (equal_id id id' && Status.to_int (Response.status r) = 100)
              "continue event"
        | _ -> failwith "missing continue");
        ignore (accepted (ok (send_data t id "abc")));
        ignore (accepted (ok (finish t id)));
        check (drain t = "abc") "continued data" );
    ( "engine/client/expect-override",
      fun () ->
        let t = ok (client ()) in
        let id =
          accepted
            (ok
               (submit_request t
                  (request ~meth:Method.post
                     [
                       ("host", "x");
                       ("content-length", "3");
                       ("expect", "100-continue");
                     ])))
        in
        ignore (drain t);
        ignore (ok (continue_request t id));
        ignore (accepted (ok (send_data t id "abc")));
        check (drain t = "abc") "override failed" );
    ( "engine/client/early-final",
      fun () ->
        let t = ok (client ()) in
        let id =
          accepted
            (ok
               (submit_request t
                  (request ~meth:Method.post
                     [ ("host", "x"); ("content-length", "3") ])))
        in
        ignore (drain t);
        ignore (accepted (ok (send_data t id "abc")));
        ignore (feed t "HTTP/1.1 413 Too Large\r\nContent-Length: 0\r\n\r\n");
        check (output t = None) "unsent upload survived early final";
        ignore (poll_event t);
        complete t id;
        check (poll_event t = Some (Closed None)) "early final reused" );
    ( "engine/client/unsolicited",
      fun () ->
        let t = ok (client ()) in
        check
          (Result.is_error (offered t "HTTP/1.1 200 OK\r\n\r\n"))
          "unsolicited response ignored" );
    ( "engine/client/info-bound",
      fun () ->
        let t = ok (client ~informational_limit:1 ()) in
        let id = accepted (ok (submit_request t (request [ ("host", "x") ]))) in
        ignore (accepted (ok (finish t id)));
        ignore (drain t);
        ignore (feed t "HTTP/1.1 103 Early Hints\r\n\r\n");
        ignore (poll_event t);
        check
          (Result.is_error (offered t "HTTP/1.1 103 Early Hints\r\n\r\n"))
          "unbounded informational responses" );
    ( "engine/abort/once",
      fun () ->
        let t, id = server_request post in
        ignore (feed t "a");
        abort t Cancelled;
        abort t Resource_limit;
        check (poll_event t = Some (Closed (Some Cancelled))) "first error lost";
        check
          (poll_event t = None && output t = None && queued_input_bytes t = 0)
          "work after abort";
        check (send_data t id "x" = Error Invalid_command) "write after abort"
    );
    ( "engine/eof/fixed",
      fun () ->
        let t, _ = server_request post in
        ignore (feed t "a");
        ignore (poll_event t);
        check
          (input_eof t = Error (Protocol Codec.Unexpected_eof))
          "truncated body completed";
        check
          (poll_event t = Some (Closed (Some (Protocol Codec.Unexpected_eof))))
          "EOF not propagated" );
    ( "engine/eof/half-close",
      fun () ->
        let t, id = server_request get in
        complete t id;
        ignore (ok (input_eof t));
        reply t id;
        check
          (String.ends_with ~suffix:"abc" (drain t))
          "half-close lost response";
        check (poll_event t = Some (Closed None)) "half-close reused" );
    ( "engine/shutdown",
      fun () ->
        let t, id = server_request get in
        complete t id;
        shutdown t;
        reply t id;
        ignore (drain t);
        check (poll_event t = Some (Closed None)) "shutdown failed";
        let t = ok (server ()) in
        shutdown t;
        check (poll_event t = Some (Closed None)) "idle shutdown" );
    ( "engine/ack/invalid",
      fun () ->
        let t, id = server_request get in
        complete t id;
        reply t id;
        let before = output t in
        check (acknowledge t max_int = Error Invalid_command) "ack overconsume";
        check
          (acknowledge t (-1) = Error Invalid_command && output t = before)
          "bad ack mutated state" );
    ( "engine/output/body-mismatch",
      fun () ->
        let t, id = server_request get in
        complete t id;
        ignore
          (accepted
             (ok (respond t id (response 200 [ ("content-length", "3") ]))));
        ignore (drain t);
        ignore (accepted (ok (send_data t id "ab")));
        check
          (finish t id = Error (Protocol Codec.Invalid_length))
          "short output completed";
        check (output t = None) "failed body retained output";
        check
          (poll_event t = Some (Closed (Some (Protocol Codec.Invalid_length))))
          "output failure hidden" );
    ( "engine/handoff/connect",
      fun () ->
        let wire = "CONNECT x:443 HTTP/1.1\r\nHost: x:443\r\n\r\n" in
        let t = ok (server ()) in
        check
          (feed t (wire ^ "TLS") = String.length wire)
          "tunnel suffix consumed";
        let id = request_id t in
        complete t id;
        ignore (accepted (ok (respond t id (response 200 []))));
        check (poll_event t = None) "handoff before flush";
        ignore (drain ~step:1 t);
        check (poll_event t = Some (Handoff id)) "handoff missing";
        abort t Cancelled;
        check (poll_event t = None) "handoff ownership revoked" );
    ( "engine/handoff/upgrade",
      fun () ->
        let t, id =
          server_request
            "GET / HTTP/1.1\r\n\
             Host: x\r\n\
             Connection: upgrade\r\n\
             Upgrade: websocket\r\n\
             \r\n"
        in
        complete t id;
        check
          (Result.is_error
             (respond t id
                (response 101
                   [ ("connection", "upgrade"); ("upgrade", "other") ])))
          "unoffered upgrade";
        ignore
          (accepted
             (ok
                (respond t id
                   (response 101
                      [ ("connection", "upgrade"); ("upgrade", "websocket") ]))));
        ignore (drain t);
        check (poll_event t = Some (Handoff id)) "upgrade handoff" );
    ( "engine/handoff/unsolicited",
      fun () ->
        let t = ok (client ()) in
        let id = accepted (ok (submit_request t (request [ ("host", "x") ]))) in
        ignore (accepted (ok (finish t id)));
        ignore (drain t);
        check
          (Result.is_error
             (offered t
                "HTTP/1.1 101 Switching\r\n\
                 Connection: upgrade\r\n\
                 Upgrade: websocket\r\n\
                 \r\n"))
          "unsolicited upgrade accepted" );
  ]

let output_properties ~seed ~count =
  let open QCheck2 in
  [
    ( "engine/property-partial-writes",
      fun () ->
        Test.check_exn
          ~rand:(Random.State.make [| seed |])
          (Test.make ~count
             (Gen.pair (Gen.int_bound 128) (Gen.int_bound 32))
             (fun (size, step) ->
               let t, id = server_request get in
               complete t id;
               let payload = String.make size 'x' in
               ignore
                 (accepted
                    (ok
                       (respond t id
                          (response 200
                             [ ("content-length", string_of_int size) ]))));
               ignore (accepted (ok (send_data t id payload)));
               ignore (accepted (ok (finish t id)));
               let wire = drain ~step:(step + 1) t in
               wire
               = Printf.sprintf "HTTP/1.1 200 \r\ncontent-length: %d\r\n\r\n%s"
                   size payload
               && queued_output_bytes t = 0)) );
  ]

let model_cases =
  [
    ( "engine/model/fair",
      fun () -> Engine_scenarios.run (String.make 200 (Char.chr 0)) );
    ( "engine/model/client",
      fun () -> Engine_scenarios.client_fragments "fragment schedule" );
  ]

let properties ~seed ~count =
  output_properties ~seed ~count
  @ List.map
      (fun (name, run) ->
        ( name,
          fun () ->
            QCheck2.Test.check_exn
              ~rand:(Random.State.make [| seed |])
              (QCheck2.Test.make ~count
                 (QCheck2.Gen.string_size (QCheck2.Gen.int_bound 128))
                 (fun bytes ->
                   run bytes;
                   true)) ))
      [
        ("engine/property-lifecycle", Engine_scenarios.run);
        ("engine/property-client", Engine_scenarios.client_fragments);
      ]

let readiness_cases =
  [
    ( "engine/readiness",
      fun () ->
        let t = ok (server ()) in
        check (input_state t = `Idle) "new server state";
        ignore (feed t "PO");
        check (input_state t = `Head) "partial header readiness";
        ignore (feed t (String.sub post 2 (String.length post - 2)));
        check (input_state t = `Blocked) "read-ahead while head queued";
        let id = request_id t in
        check (input_state t = `Body) "body readiness";
        ignore (feed t "abc");
        check (input_state t = `Blocked) "read-ahead while data queued";
        ignore (poll_event t);
        complete t id;
        reply t id;
        ignore (drain t);
        check (input_state t = `Idle) "persistence readiness";
        check (max_send_size t = 16384) "send chunk budget" );
  ]

let handoff_domain_cases =
  [
    ( "engine/handoff/client-connect",
      fun () ->
        let t = ok (client ()) in
        let id =
          accepted
            (ok
               (submit_request t
                  (request ~meth:Method.connect ~target:"x:443"
                     [ ("host", "x:443") ])))
        in
        ignore (accepted (ok (finish t id)));
        ignore (drain t);
        let wire = "HTTP/1.1 200 OK\r\n\r\n" in
        check
          (feed t (wire ^ "TLS") = String.length wire)
          "client tunnel suffix consumed";
        (match poll_event t with
        | Some (Response (id', _)) ->
            check (equal_id id id') "handoff response id"
        | _ -> failwith "missing response");
        check (poll_event t = Some (Handoff id)) "client handoff missing" );
    ( "engine/model/domains",
      fun () ->
        List.iter
          (fun count ->
            let domains =
              List.init count (fun _ ->
                  Domain.spawn (fun () ->
                      for _ = 1 to 100 do
                        Engine_scenarios.run "\000\001\002\003";
                        Engine_scenarios.client_fragments "domains"
                      done))
            in
            List.iter Domain.join domains)
          [ 1; 2; 4 ] );
  ]

let cases =
  protocol_cases @ model_cases @ readiness_cases @ handoff_domain_cases
