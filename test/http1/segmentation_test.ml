open Httpkit_core
open Httpkit_http1
open Segmentation_support

let run () =
  List.iter
    (fun (name, role, wire, framing) ->
      let input = wire ^ marker in
      let expected = head ~step:16384 role input [ String.length input ] in
      (match expected with
      | Ok (n, m) ->
          check (n = String.length wire && m.framing = framing) "golden head"
      | Error _ -> failwith "golden head rejected");
      matrix name input (fun ~step cuts -> head ~step role input cuts) expected)
    Http1_cases.valid_heads;
  let bad_responses =
    List.map
      (fun fields -> "HTTP/1.1 200 OK\r\n" ^ fields ^ "\r\n")
      [
        "Content-Length: 1\r\nContent-Length: 1\r\n";
        "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n";
        "Transfer-Encoding: gzip, chunked\r\n";
        "Content-Length: -1\r\n";
        "Content-Length: 9223372036854775808\r\n";
      ]
  in
  let rejected =
    List.map (fun (n, w) -> (n, Request, w)) Http1_cases.invalid_requests
    @ List.mapi
        (fun i w -> ("response-" ^ string_of_int i, Response Method.get, w))
        bad_responses
  in
  List.iter
    (fun (name, role, wire) ->
      let wire = wire ^ marker in
      let expected = head ~step:16384 role wire [ String.length wire ] in
      check (Result.is_error expected) "malformed head accepted";
      matrix name wire (fun ~step cuts -> head ~step role wire cuts) expected)
    rejected;
  let close_meta =
    snd
      (ok
         (encode_response ~request_method:Method.get
            (Http1_cases.response 200 [])))
  in
  let valid_bodies =
    [
      (Http1_cases.fixed_meta, "abc" ^ marker, (3, "abc", []));
      (Http1_cases.chunk_meta, "3\r\nabc\r\n0\r\n\r\n" ^ marker, (13, "abc", []));
      (close_meta, "abc", (3, "abc", []));
    ]
  in
  List.iter
    (fun (meta, wire, expected) ->
      matrix "valid-body" wire
        (fun ~step cuts -> body ~step meta wire cuts)
        (Ok expected))
    valid_bodies;
  List.iter
    (fun wire ->
      let expected =
        body ~step:16384 Http1_cases.chunk_meta wire [ String.length wire ]
      in
      check (Result.is_error expected) "malformed chunk accepted";
      matrix "chunk-rejection" wire
        (fun ~step cuts -> body ~step Http1_cases.chunk_meta wire cuts)
        expected)
    [
      "g\r\n";
      "-1\r\n";
      "8000000000000000\r\n";
      "1;\r\na\r\n0\r\n\r\n";
      "1;x=\"unterminated\r\n";
      "1\r\naX\n0\r\n\r\n";
      "0\r\ncontent-length: 0\r\n\r\n";
      "0\r\nx-undeclared: yes\r\n\r\n";
      "0\r\n digest: x\r\n\r\n";
    ];
  List.iter
    (fun (role, wire) ->
      for n = 0 to String.length wire - 1 do
        let prefix = String.sub wire 0 n in
        matrix "head-eof" prefix
          (fun ~step cuts -> head ~step role prefix cuts)
          (Error Unexpected_eof)
      done)
    [
      (Request, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
      (Response Method.get, "HTTP/1.1 200 OK\r\n\r\n");
    ];
  List.iter
    (fun (meta, wire) ->
      for n = 0 to String.length wire - 1 do
        let prefix = String.sub wire 0 n in
        matrix "body-eof" prefix
          (fun ~step cuts -> body ~step meta prefix cuts)
          (Error Unexpected_eof)
      done)
    [
      (Http1_cases.fixed_meta, "abc");
      (Http1_cases.chunk_meta, "3\r\nabc\r\n0\r\n\r\n");
    ]

let () =
  Alcotest.run "HTTP/1 segmentation"
    [ ("corpus", [ Alcotest.test_case "schedule invariants" `Quick run ]) ]
