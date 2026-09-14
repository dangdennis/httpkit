open Httpkit_core
module C = Httpkit_http1
module E = Httpkit_engine
module S = Segmentation_support

let check = S.check
let ok = Engine_cases.ok

let codec () =
  List.iter
    (fun (name, fields, expected) ->
      List.iter
        (fun (role, wire) ->
          let input = wire ^ S.marker in
          S.matrix name input
            (fun ~step cuts ->
              Result.map
                (fun (n, (meta : C.metadata)) -> (n, meta.framing))
                (S.head ~step role input cuts))
            (Result.map (fun framing -> (String.length wire, framing)) expected))
        [
          (C.Request, Framing_cases.request fields);
          (C.Response Method.get, Framing_cases.response fields);
        ];
      let hs = ("host", "x") :: fields in
      let encoded_request = C.encode_request (Http1_cases.request hs) in
      let encoded_response =
        C.encode_response ~request_method:Method.get
          (Http1_cases.response 200 fields)
      in
      List.iter
        (fun result ->
          check
            (Result.map (fun (_, (m : C.metadata)) -> m.framing) result
            = expected)
            (name ^ " encoder policy"))
        [ encoded_request; encoded_response ])
    Framing_cases.fields

let isolation () =
  List.iter
    (fun (name, fields, expected) ->
      match expected with
      | Ok _ -> ()
      | Error error ->
          let wire = Framing_cases.request fields ^ S.marker in
          List.iter
            (fun step ->
              List.iter
                (fun (schedule, cuts) ->
                  let t = ok (E.server ~limits:(S.ok (C.limits ~step ())) ()) in
                  let offered = S.window cuts (String.length wire) in
                  let label = name ^ "/" ^ schedule in
                  let rec loop pos =
                    check
                      (pos < String.length wire)
                      (label ^ " accepted malformed request");
                    let len = offered pos in
                    match E.offer t wire ~off:pos ~len with
                    | Ok n ->
                        check (n > 0 && n <= min step len) (label ^ " progress");
                        check
                          (E.poll_event t = None)
                          (label ^ " premature dispatch");
                        loop (pos + n)
                    | Error e ->
                        check (e = E.Protocol error) (label ^ " error class");
                        check
                          (E.input_state t = `Closed)
                          (label ^ " did not close");
                        E.abort t E.Cancelled;
                        check
                          (E.poll_event t = Some (E.Closed (Some e)))
                          (label ^ " lost failure");
                        check
                          (E.poll_event t = None)
                          (label ^ " repeated closure");
                        check
                          (E.offer t S.marker ~off:0
                             ~len:(String.length S.marker)
                          = Error E.Invalid_command)
                          (label ^ " suffix admitted");
                        check
                          (E.queued_input_bytes t = 0
                          && E.queued_output_bytes t = 0)
                          (label ^ " retained queues");
                        check
                          (E.poll_event t = None)
                          (label ^ " suffix dispatched")
                  in
                  loop 0)
                (S.schedules (String.length wire)))
            [ 1; 7; 16384 ])
    Framing_cases.fields

let () =
  Alcotest.run "HTTP/1 framing policy"
    [
      ( "matrix",
        [
          Alcotest.test_case "codec and encoder" `Quick codec;
          Alcotest.test_case "engine rejection isolation" `Quick isolation;
        ] );
    ]
