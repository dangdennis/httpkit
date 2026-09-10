open Http_kit_http1
open Http_kit_core

let parse role wire step =
  let d = head_decoder role in
  let rec loop off =
    let len = min step (String.length wire - off) in
    match feed_head d wire ~off ~len with
    | Error e -> Error e
    | Ok (n, Some meta) -> Ok (off + n, meta)
    | Ok (0, None) -> Error Unexpected_eof
    | Ok (n, None) -> loop (off + n)
  in
  loop 0

let check_head role wire =
  let whole = parse role wire max_int in
  let fragmented = parse role wire 1 in
  Crowbar.check (whole = fragmented);
  match whole with
  | Error _ -> ()
  | Ok (_, meta) -> (
      let encoded =
        match (meta.head, role) with
        | Request_head r, _ -> encode_request r
        | Response_head r, Response meth ->
            encode_response ~request_method:meth r
        | _ -> assert false
      in
      match encoded with
      | Error Limit_exceeded ->
          () (* Canonical colon/SP can increase wire size. *)
      | Error _ -> Crowbar.check false
      | Ok (wire, _) -> (
          match parse role wire 1 with
          | Ok (n, decoded) ->
              Crowbar.check (n = String.length wire && decoded = meta)
          | Error _ -> Crowbar.check false))

let chunk_meta =
  let hs =
    Result.get_ok
      (Headers.of_list
         [
           ("host", "x"); ("transfer-encoding", "chunked"); ("trailer", "digest");
         ])
  in
  let r =
    Request.create ~meth:Method.post
      ~target:(Result.get_ok (Target.of_string "/"))
      ~headers:hs ()
  in
  snd (Result.get_ok (encode_request r))

let chunks wire step =
  let d = body_decoder chunk_meta in
  let rec loop off data trailers count =
    Crowbar.check (count <= (2 * String.length wire) + 4);
    match feed_body d wire ~off ~len:(min step (String.length wire - off)) with
    | Error e -> Error e
    | Ok (n, Some End) ->
        Ok (off + n, String.concat "" (List.rev data), trailers)
    | Ok (n, Some (Data bytes)) ->
        loop (off + n) (bytes :: data) trailers (count + 1)
    | Ok (n, Some (Trailers hs)) ->
        loop (off + n) data (Headers.to_list hs) (count + 1)
    | Ok (0, None) -> Error Unexpected_eof
    | Ok (n, None) -> loop (off + n) data trailers (count + 1)
  in
  loop 0 [] [] 0

let bounded f bytes = if String.length bytes <= 65536 then f bytes

let () =
  Crowbar.add_test ~name:"request fragmentation and serializer"
    [ Crowbar.bytes ]
    (bounded (check_head Request));
  Crowbar.add_test ~name:"response fragmentation and serializer"
    [ Crowbar.bytes ]
    (bounded (check_head (Response Method.get)));
  Crowbar.add_test ~name:"chunked fragmentation and progress" [ Crowbar.bytes ]
    (bounded (fun wire -> Crowbar.check (chunks wire max_int = chunks wire 1)))
