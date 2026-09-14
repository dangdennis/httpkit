open Httpkit_core
open Httpkit_http1
module S = Segmentation_support

(* Headers retain their construction limits internally; wire round trips promise
   public values, not identical private collection representations. *)
let semantics m =
  match m.head with
  | Response_head r ->
      ( Response.status r,
        Response.version r,
        Headers.to_list (Response.headers r),
        m.framing,
        m.persistent,
        m.expect_continue,
        m.trailer_names )
  | Request_head _ -> failwith "expected response"

let cases =
  let cl = [ ("content-length", "3") ]
  and te = [ ("transfer-encoding", "chunked") ] in
  let bodyless =
    List.concat_map
      (fun status ->
        [
          (Method.get, status, [], Ok (if status = 101 then Tunnel else Empty));
          (Method.get, status, cl, Error Ambiguous_framing);
          (Method.get, status, te, Error Ambiguous_framing);
        ])
      (204 :: List.init 100 (fun i -> 100 + i))
  in
  bodyless
  @ [
      (Method.head, 200, [], Ok Empty);
      (Method.head, 200, cl, Ok Empty);
      (Method.head, 200, te, Ok Empty);
      (Method.head, 200, cl @ te, Error Ambiguous_framing);
      (Method.get, 304, [], Ok Empty);
      (Method.get, 304, cl, Ok Empty);
      (Method.get, 304, te, Ok Empty);
      (Method.get, 304, cl @ te, Error Ambiguous_framing);
      (Method.connect, 200, [], Ok Tunnel);
      (Method.connect, 299, [], Ok Tunnel);
      (Method.connect, 200, cl, Error Ambiguous_framing);
      (Method.connect, 200, te, Error Ambiguous_framing);
      (Method.connect, 407, cl, Ok (Fixed 3L));
      (Method.get, 200, [], Ok Close_delimited);
      (Method.get, 200, cl, Ok (Fixed 3L));
      (Method.get, 200, te, Ok Chunked);
    ]

let policy () =
  List.iter
    (fun (meth, status, fields, expected) ->
      let label = Method.to_string meth ^ " " ^ string_of_int status in
      let wire =
        Printf.sprintf "HTTP/1.1 %d reason\r\n" status
        ^ Framing_cases.wire_fields fields
        ^ "\r\n"
      in
      let input = wire ^ S.marker in
      S.matrix label input
        (fun ~step cuts ->
          Result.map
            (fun (n, m) -> (n, m.framing))
            (S.head ~step (Response meth) input cuts))
        (Result.map (fun framing -> (String.length wire, framing)) expected);
      let encoded =
        encode_response ~request_method:meth
          (Http1_cases.response status fields)
      in
      S.check
        (Result.map (fun (_, m) -> m.framing) encoded = expected)
        (label ^ " encoder policy");
      match encoded with
      | Error _ -> ()
      | Ok (serialized, meta) -> (
          S.matrix (label ^ " roundtrip") serialized
            (fun ~step cuts ->
              Result.map
                (fun (n, m) -> (n, semantics m))
                (S.head ~step (Response meth) serialized cuts))
            (Ok (String.length serialized, semantics meta));
          match meta.framing with
          | Empty ->
              S.matrix (label ^ " empty") S.marker
                (fun ~step cuts -> S.body ~step meta S.marker cuts)
                (Ok (0, "", []))
          | Tunnel ->
              let decoder = body_decoder meta in
              S.check
                (feed_body decoder S.marker ~off:0 ~len:(String.length S.marker)
                = Error Invalid_state)
                (label ^ " tunnel parsed as HTTP")
          | _ -> ()))
    cases

let close_framing () =
  let _, meta =
    S.ok
      (encode_response ~request_method:Method.get (Http1_cases.response 200 []))
  in
  S.check (not meta.persistent) "close-framed response reused";
  S.matrix "close body" S.marker
    (fun ~step cuts -> S.body ~step meta S.marker cuts)
    (Ok (String.length S.marker, S.marker, []));
  let decoder = body_decoder meta in
  S.check
    (feed_body decoder "" ~off:0 ~len:0 = Ok (0, None))
    "empty input became EOF";
  S.check (eof_body decoder = Ok (Some End)) "real EOF failed to finish";
  S.check (eof_body decoder = Ok None) "EOF duplicated End"

let () =
  Alcotest.run "HTTP/1 response policy"
    [
      ( "matrix",
        [
          Alcotest.test_case "special responses and encoder parity" `Quick
            policy;
          Alcotest.test_case "close framing requires EOF" `Quick close_framing;
        ] );
    ]
