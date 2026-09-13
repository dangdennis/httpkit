open Httpkit_core
module E = Httpkit_engine
module C = Httpkit_http1

let ok = Result.get_ok
let accept = function Ok (E.Accepted x) -> x | _ -> failwith "not accepted"

let reject = function
  | Error _ -> ()
  | Ok _ -> failwith "invalid command accepted"

let request fields =
  Request.create ~meth:Method.get
    ~target:(ok (Target.of_string "/"))
    ~headers:(ok (Headers.of_list fields))
    ()

let response status fields =
  Response.create
    ~status:(ok (Status.of_int status))
    ~headers:(ok (Headers.of_list fields))
    ()

let get = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
let offer e s = ok (E.offer e s ~off:0 ~len:(String.length s))

let server ?(output_limit = 65536) ?(informational_limit = 16) wire =
  let e = ok (E.server ~output_limit ~informational_limit ()) in
  ignore (offer e wire);
  let id =
    match E.poll_event e with
    | Some (E.Request (id, _)) -> id
    | _ -> assert false
  in
  (e, id)

let drain e =
  let rec loop () =
    match E.output e with
    | None -> ()
    | Some (_, _, n) ->
        ignore (ok (E.acknowledge e n));
        loop ()
  in
  loop ()

let diagnostics () =
  List.iter
    (fun error ->
      let s = E.error_to_string error in
      assert (String.length s > 0 && String.length s < 64))
    [
      E.Invalid_command;
      E.Resource_limit;
      E.Cancelled;
      E.Protocol C.Invalid_length;
    ];
  reject (E.server ~output_limit:0 ());
  reject (E.client ~informational_limit:(-1) ());
  let e = ok (E.client ~output_limit:1 ()) in
  reject (E.submit_request e (request [ ("host", "x") ]));
  let e = ok (E.client ()) in
  reject (E.submit_request e (request []));
  let id = accept (E.submit_request e (request [ ("host", "x") ])) in
  assert (E.submit_request e (request [ ("host", "x") ]) = Ok E.Backpressured);
  ignore (accept (E.finish e id));
  reject (E.send_data e id "");
  reject (E.finish e id);
  reject (E.continue_request e id);
  E.shutdown e;
  reject (E.submit_request e (request [ ("host", "x") ]))

let invalid_commands () =
  let e, id = server get in
  reject (E.submit_request e (request [ ("host", "x") ]));
  reject (E.send_data e id "abc");
  reject (E.finish e id);
  reject (E.continue_request e id);
  List.iter
    (fun (off, len) -> reject (E.offer e "x" ~off ~len))
    [ (-1, 0); (0, -1); (2, 0); (0, 2) ];
  E.abort e E.Cancelled;
  reject (E.offer e "x" ~off:0 ~len:1);
  assert (E.input_eof e = Ok ());
  let e, id = server ~informational_limit:0 get in
  reject (E.respond e id (response 103 []));
  reject (E.respond e id (response 204 [ ("content-length", "0") ]));
  ignore (accept (E.respond e id (response 200 [ ("content-length", "1") ])));
  reject (E.respond e id (response 200 []));
  reject (E.send_data e id "ab");
  assert (E.input_state e = `Closed)

let eof () =
  let e = ok (E.server ()) in
  assert (E.input_eof e = Ok ());
  assert (E.poll_event e = Some (E.Closed None));
  let e = ok (E.server ()) in
  ignore (offer e "GET / HT");
  reject (E.input_eof e);
  let e, id =
    server "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n"
  in
  ignore (offer e "abc");
  ignore (ok (E.discard_body e id));
  assert (E.poll_event e = Some (E.Complete id));
  let e = ok (E.client ()) in
  let id = accept (E.submit_request e (request [ ("host", "x") ])) in
  ignore (accept (E.finish e id));
  drain e;
  ignore (offer e "HTTP/1.1 200 OK\r\n\r\n");
  (match E.poll_event e with Some (E.Response _) -> () | _ -> assert false);
  ignore (offer e "abc");
  (match E.poll_event e with
  | Some (E.Data (_, "abc")) -> ()
  | _ -> assert false);
  assert (E.input_eof e = Ok ());
  assert (E.poll_event e = Some (E.Complete id));
  assert (E.poll_event e = Some (E.Closed None))

let upgrade () =
  List.iter
    (fun protocol ->
      let e, id =
        server
          ("GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: "
         ^ protocol ^ "\r\n\r\n")
      in
      ignore (E.poll_event e);
      let selected = if protocol = "proto/1" then "proto/2" else protocol in
      reject
        (E.respond e id
           (response 101 [ ("connection", "upgrade"); ("upgrade", selected) ])))
    [ "proto/1" ];
  List.iter
    (fun protocol ->
      let e = ok (E.server ()) in
      let wire =
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: "
        ^ protocol ^ "\r\n\r\n"
      in
      reject (E.offer e wire ~off:0 ~len:(String.length wire)))
    [ "a/b/c"; "a/" ];
  let e, id = server get in
  ignore (E.poll_event e);
  reject
    (E.respond e id
       (response 101 [ ("connection", "upgrade"); ("upgrade", "websocket") ]));
  let e, id =
    server
      "GET / HTTP/1.1\r\n\
       Host: x\r\n\
       Connection: upgrade\r\n\
       Upgrade: proto/1\r\n\
       \r\n"
  in
  ignore (E.poll_event e);
  ignore
    (accept
       (E.respond e id
          (response 101 [ ("connection", "upgrade"); ("upgrade", "proto/1") ])));
  drain e;
  assert (E.poll_event e = Some (E.Handoff id))

let finish_capacity () =
  let e, id = server ~output_limit:100 get in
  ignore (E.poll_event e);
  ignore
    (accept
       (E.respond e id
          (response 200
             [ ("transfer-encoding", "chunked"); ("trailer", "digest") ])));
  let trailers = ok (Headers.of_list [ ("digest", String.make 32 'a') ]) in
  assert (E.finish ~trailers e id = Ok E.Backpressured);
  drain e;
  ignore (accept (E.finish ~trailers e id));
  drain e;
  let e, id = server ~output_limit:10 get in
  ignore (E.poll_event e);
  reject (E.respond e id (response 200 []))

let expect_finalization () =
  List.iter
    (fun fields ->
      List.iter
        (fun override ->
          let e = ok (E.client ()) in
          let req =
            Request.create ~meth:Method.post
              ~target:(ok (Target.of_string "/"))
              ~headers:
                (ok
                   (Headers.of_list
                      (("host", "x") :: ("expect", "100-continue") :: fields)))
              ()
          in
          let id = accept (E.submit_request e req) in
          drain e;
          assert (E.send_data e id "" = Ok E.Backpressured);
          assert (E.finish e id = Ok E.Backpressured);
          assert (E.output e = None);
          if override then ignore (ok (E.continue_request e id))
          else (
            ignore (offer e "HTTP/1.1 103 Early Hints\r\n\r\n");
            ignore (E.poll_event e);
            assert (E.finish e id = Ok E.Backpressured);
            ignore (offer e "HTTP/1.1 100 Continue\r\n\r\n");
            ignore (E.poll_event e));
          ignore (accept (E.finish e id));
          reject (E.finish e id);
          drain e)
        [ false; true ])
    [ [ ("content-length", "0") ]; [ ("transfer-encoding", "chunked") ] ]

let () =
  Alcotest.run "Engine boundary regressions"
    [
      ( "public contracts",
        List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          [
            ("configuration and diagnostics", diagnostics);
            ("invalid commands", invalid_commands);
            ("EOF and discard", eof);
            ("upgrade negotiation", upgrade);
            ("trailer capacity", finish_capacity);
            ("Expect finalization permission", expect_finalization);
          ] );
    ]
