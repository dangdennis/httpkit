module C = Httpkit_http1
module E = Httpkit_engine
module S = Segmentation_support

let check = S.check
let ok = Engine_cases.ok

let codec () =
  List.iter
    (fun (name, wire, data, trailers) ->
      let input = wire ^ S.marker in
      S.matrix name input
        (fun ~step cuts -> S.body ~step Chunk_cases.meta input cuts)
        (Ok
           ( String.length wire,
             data,
             Httpkit_core.Headers.to_list
               (Result.get_ok (Httpkit_core.Headers.of_list trailers)) )))
    Chunk_cases.valid;
  List.iter
    (fun (name, wire, error) ->
      let input = wire ^ S.marker in
      S.matrix name input
        (fun ~step cuts -> S.body ~step Chunk_cases.meta input cuts)
        (Error error))
    Chunk_cases.invalid;
  List.iter
    (fun (name, quota, wire, expected) ->
      S.matrix name wire
        (fun ~step cuts ->
          S.body
            ~configure:(fun step -> S.ok (C.limits ~step ~body:quota ()))
            ~step Chunk_cases.meta wire cuts)
        expected)
    [
      ("exact-quota", 3L, "1\r\na\r\n2\r\nbc\r\n0\r\n\r\n", Ok (18, "abc", []));
      ( "cumulative-quota",
        2L,
        "1\r\na\r\n2\r\nbc\r\n0\r\n\r\n",
        Error C.Limit_exceeded );
      ("huge-declared-chunk", 3L, "7fffffffffffffff\r\n", Error C.Limit_exceeded);
    ]

let isolation () =
  List.iter
    (fun (name, payload, error) ->
      let wire = Chunk_cases.head ^ payload ^ S.marker in
      List.iter
        (fun discard ->
          List.iter
            (fun step ->
              List.iter
                (fun (schedule, cuts) ->
                  let t = ok (E.server ~limits:(S.ok (C.limits ~step ())) ()) in
                  let offered = S.window cuts (String.length wire) in
                  let requests = ref 0 in
                  let label = name ^ "/" ^ schedule in
                  let rec loop pos calls =
                    check
                      (calls < 2 * String.length wire)
                      (label ^ " progress budget");
                    check
                      (pos < String.length wire)
                      (label ^ " failed to reject");
                    let len = offered pos in
                    match E.offer t wire ~off:pos ~len with
                    | Ok n ->
                        check
                          (n > 0 && n <= min step len)
                          (label ^ " consumption");
                        (match E.poll_event t with
                        | Some (E.Request (id, _)) ->
                            incr requests;
                            if discard then ignore (ok (E.discard_body t id))
                        | Some (E.Data _) ->
                            check (not discard) (label ^ " discard emitted data")
                        | None -> ()
                        | _ -> failwith (label ^ " premature completion"));
                        loop (pos + n) (calls + 1)
                    | Error e ->
                        check
                          (!requests = 1 && e = E.Protocol error)
                          (label ^ " rejection");
                        check
                          (E.poll_event t = Some (E.Closed (Some e)))
                          (label ^ " close");
                        check
                          (E.queued_input_bytes t = 0
                          && E.queued_output_bytes t = 0)
                          (label ^ " retained queues");
                        check
                          (E.offer t S.marker ~off:0
                             ~len:(String.length S.marker)
                          = Error E.Invalid_command)
                          (label ^ " suffix reuse");
                        check (E.poll_event t = None) (label ^ " extra dispatch")
                  in
                  loop 0 0)
                (S.schedules (String.length wire)))
            [ 1; 7; 16384 ])
        [ false; true ])
    Chunk_cases.invalid

let () =
  Alcotest.run "HTTP/1 chunk policy"
    [
      ( "matrix",
        [
          Alcotest.test_case "explicit codec outcomes" `Quick codec;
          Alcotest.test_case "body and discard rejection isolation" `Quick
            isolation;
        ] );
    ]
