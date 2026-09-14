open Httpkit_core
open Httpkit_http1

let check = Http1_cases.check
let ok = Http1_cases.ok
let marker = "GET /marker HTTP/1.1\r\nHost: marker\r\n\r\n"

(* Boundaries belong to the supplied stream, not to calls: a codec work limit
   may stop inside a segment, whose remaining suffix must be offered again. *)
let window boundaries length =
  let pending = ref boundaries in
  fun pos ->
    let rec skip () =
      match !pending with
      | n :: rest when n <= pos ->
          pending := rest;
          skip ()
      | n :: _ -> n - pos
      | [] -> length - pos
    in
    skip ()

let schedules length =
  let random seed =
    let state = Random.State.make [| seed; length |] in
    let rec loop pos acc =
      if pos = length then List.rev acc
      else
        let next = min length (pos + 1 + Random.State.int state 19) in
        loop next (next :: acc)
    in
    loop 0 []
  in
  ("whole", [ length ])
  :: ("bytes", List.init length (( + ) 1))
  :: (List.init (length + 1) (fun split ->
          ("split-" ^ string_of_int split, [ split; length ]))
     @ List.init 8 (fun seed -> ("seed-" ^ string_of_int seed, random seed)))

let head ~step role wire cuts =
  let decoder = head_decoder ~limits:(ok (limits ~step ())) role in
  let offered = window cuts (String.length wire) in
  let terminal error =
    check
      (feed_head decoder marker ~off:0 ~len:(String.length marker) = Error error)
      "failed head revived on marker";
    check (eof_head decoder = Error error) "head EOF changed terminal error";
    Error error
  in
  let rec loop pos calls =
    check (calls <= String.length wire + 2) "head progress budget";
    let len = offered pos in
    match feed_head decoder wire ~off:pos ~len with
    | Error e -> terminal e
    | Ok (n, meta) -> (
        check
          (n >= 0 && n <= min step len)
          "head consumed outside offered prefix";
        match meta with
        | Some meta ->
            check (eof_head decoder = Ok ()) "complete head EOF";
            Ok (pos + n, meta)
        | None when len = 0 -> (
            match eof_head decoder with
            | Error e -> terminal e
            | Ok () -> failwith "missing head")
        | None ->
            check (n > 0) "head stalled with input";
            loop (pos + n) (calls + 1))
  in
  loop 0 0

let body ~step meta wire cuts =
  let decoder = body_decoder ~limits:(ok (limits ~step ())) meta in
  let offered = window cuts (String.length wire) in
  let output = Buffer.create 32 in
  let trailers = ref [] in
  let terminal error =
    check
      (feed_body decoder marker ~off:0 ~len:(String.length marker) = Error error)
      "failed body revived on marker";
    check (eof_body decoder = Error error) "body EOF changed terminal error";
    Error error
  in
  let finished pos =
    check (eof_body decoder = Ok None) "body End repeated at EOF";
    Ok (pos, Buffer.contents output, !trailers)
  in
  let rec loop pos calls =
    check (calls <= (2 * String.length wire) + 8) "body progress budget";
    let len = offered pos in
    match feed_body decoder wire ~off:pos ~len with
    | Error e -> terminal e
    | Ok (n, event) -> (
        check
          (n >= 0 && n <= min step len)
          "body consumed outside offered prefix";
        match event with
        | Some End -> finished (pos + n)
        | Some (Data bytes) ->
            check
              (bytes <> "" && String.length bytes <= step)
              "invalid data event";
            Buffer.add_string output bytes;
            loop (pos + n) (calls + 1)
        | Some (Trailers hs) ->
            trailers := Headers.to_list hs;
            loop (pos + n) (calls + 1)
        | None when len = 0 -> (
            match eof_body decoder with
            | Error e -> terminal e
            | Ok (Some End) -> finished pos
            | _ -> failwith "EOF did not resolve body")
        | None ->
            check (n > 0) "body stalled with input";
            loop (pos + n) (calls + 1))
  in
  loop 0 0

let matrix name wire run expected =
  List.iter
    (fun step ->
      List.iter
        (fun (schedule, cuts) ->
          check
            (run ~step cuts = expected)
            (Printf.sprintf "%s step=%d schedule=%s" name step schedule))
        (schedules (String.length wire)))
    [ 1; 7; 16384 ]

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
