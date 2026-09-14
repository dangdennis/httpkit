open Httpkit_core
module C = Httpkit_http1
module E = Httpkit_engine
module S = Segmentation_support

let check = S.check
let ok = Engine_cases.ok
let accepted = Engine_cases.accepted

let exchanges =
  [
    (Framing_cases.request [ ("Content-Length", "3") ], "abc", "abc");
    (Chunk_cases.head, "1\r\na\r\n2\r\nbc\r\n0\r\n\r\n", "abc");
    (Engine_cases.get, "", "");
  ]

let reuse () =
  List.iter
    (fun (head, body, expected) ->
      let wire = head ^ body ^ S.marker in
      List.iter
        (fun discard ->
          List.iter
            (fun step ->
              List.iter
                (fun (schedule, cuts) ->
                  let t = ok (E.server ~limits:(S.ok (C.limits ~step ())) ()) in
                  let offered = S.window cuts (String.length wire) in
                  let first = ref None and current = ref None in
                  let requests = ref 0 and completed = ref 0 in
                  let data = Buffer.create 3 in
                  let pos = ref 0 in
                  let rec events () =
                    match E.poll_event t with
                    | None -> ()
                    | Some (E.Request (id, r)) ->
                        incr requests;
                        current := Some id;
                        if !requests = 1 then (
                          first := Some id;
                          if discard then ignore (ok (E.discard_body t id)))
                        else (
                          check
                            (!requests = 2 && !completed = 1)
                            (schedule ^ " early next request");
                          check
                            (Target.to_string (Request.target r) = "/marker")
                            "suffix corrupted";
                          check
                            (not (E.equal_id id (Option.get !first)))
                            "exchange id reused");
                        events ()
                    | Some (E.Data (id, chunk)) ->
                        check
                          (E.equal_id id (Option.get !current)
                          && !requests = 1 && not discard)
                          "cross-exchange or discarded data";
                        Buffer.add_string data chunk;
                        events ()
                    | Some (E.Trailers _) -> events ()
                    | Some (E.Complete id) ->
                        incr completed;
                        check
                          (E.equal_id id (Option.get !current))
                          "completion identity";
                        ignore
                          (accepted
                             (ok
                                (E.respond t id
                                   (Engine_cases.response 200
                                      [ ("content-length", "0") ]))));
                        ignore (accepted (ok (E.finish t id)));
                        if !completed = 1 then (
                          check
                            (!pos = String.length head + String.length body)
                            "body suffix consumed";
                          check
                            (E.offer t wire ~off:!pos
                               ~len:(String.length wire - !pos)
                            = Ok 0)
                            "next request admitted before output \
                             acknowledgement");
                        let rec drain () =
                          match E.output t with
                          | None -> ()
                          | Some (_, _, len) ->
                              if !completed = 1 then
                                check
                                  (E.offer t wire ~off:!pos
                                     ~len:(String.length wire - !pos)
                                  = Ok 0)
                                  "request admitted during partial \
                                   acknowledgement";
                              ignore (ok (E.acknowledge t (min step len)));
                              drain ()
                        in
                        drain ();

                        events ()
                    | _ -> failwith "unexpected lifecycle event"
                  in
                  let rec feed calls =
                    check
                      (calls <= String.length wire + 4)
                      "reuse progress budget";
                    events ();
                    if !completed < 2 then (
                      let len = offered !pos in
                      let n = ok (E.offer t wire ~off:!pos ~len) in
                      check (n > 0 && n <= min step len) "reuse stalled";
                      pos := !pos + n;
                      feed (calls + 1))
                  in
                  feed 0;
                  check
                    (!pos = String.length wire && !requests = 2)
                    "incomplete pipeline";
                  check
                    (Buffer.contents data = if discard then "" else expected)
                    "body mismatch";
                  check
                    (E.queued_input_bytes t = 0 && E.queued_output_bytes t = 0)
                    "retained queues";
                  E.shutdown t;
                  check (E.poll_event t = Some (E.Closed None)) "idle shutdown";
                  check (E.poll_event t = None) "duplicate shutdown")
                (S.schedules (String.length wire)))
            [ 1; 7; 16384 ])
        [ false; true ])
    exchanges

let early_rejection () =
  List.iter
    (fun (head, body, _) ->
      if body <> "" then
        List.iter
          (fun bytes_read ->
            let t, id = Engine_cases.server_request head in
            if bytes_read > 0 then (
              ignore (ok (E.offer t body ~off:0 ~len:bytes_read));
              ignore (E.poll_event t));
            ignore
              (accepted
                 (ok
                    (E.respond t id
                       (Engine_cases.response 413 [ ("content-length", "0") ]))));
            check
              (E.poll_event t = Some (E.Body_aborted id))
              "early response did not abort body";
            ignore (accepted (ok (E.finish t id)));
            let suffix =
              String.sub body bytes_read (String.length body - bytes_read)
              ^ S.marker
            in
            check
              (E.offer t suffix ~off:0 ~len:(String.length suffix) = Ok 0)
              "early suffix consumed";
            ignore (Engine_cases.drain ~step:1 t);
            check
              (E.poll_event t = Some (E.Closed None))
              "early response reused";
            check
              (E.offer t suffix ~off:0 ~len:(String.length suffix)
              = Error E.Invalid_command)
              "closed early response accepted suffix")
          [ 0; 1 ])
    exchanges

let () =
  Alcotest.run "HTTP/1 reuse schedules"
    [
      ( "lifecycle",
        [
          Alcotest.test_case "pipeline and discard" `Quick reuse;
          Alcotest.test_case "early rejection" `Quick early_rejection;
        ] );
    ]
