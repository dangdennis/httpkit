open Httpkit_http1
open Httpkit_core
module Segmentation = Segmentation_support

let parse role wire step =
  let cuts =
    if step = 1 then List.init (String.length wire) (( + ) 1)
    else [ String.length wire ]
  in
  Segmentation.head ~step:16384 role wire cuts

let variants run wire expected =
  List.iter
    (fun seed ->
      Crowbar.check
        (run ~step:7 (Segmentation.random_cuts (String.length wire) seed)
        = expected))
    [ 0; 17 ]

let check_head role wire =
  let whole = parse role wire max_int in
  let fragmented = parse role wire 1 in
  Crowbar.check (whole = fragmented);
  variants (fun ~step cuts -> Segmentation.head ~step role wire cuts) wire whole;
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
  let cuts =
    if step = 1 then List.init (String.length wire) (( + ) 1)
    else [ String.length wire ]
  in
  Segmentation.body ~step:16384 chunk_meta wire cuts

let check_chunks wire =
  let whole = chunks wire max_int in
  Crowbar.check (whole = chunks wire 1);
  variants
    (fun ~step cuts -> Segmentation.body ~step chunk_meta wire cuts)
    wire whole

let bounded f bytes = if String.length bytes <= 65536 then f bytes

let () =
  let selected = Sys.getenv_opt "HTTP_KIT_FUZZ_CASE" in
  if
    not
      (List.mem selected
         [ None; Some "request"; Some "response"; Some "chunked" ])
  then invalid_arg "unknown fuzz case";
  let add name f =
    if selected = None || selected = Some name then
      Fuzz_input.add ~name (bounded f)
  in
  add "request" (fun wire ->
      check_head Request wire;
      (* Grammar-aware companion keeps semantic states reachable while arbitrary
       bytes exercise rejection. The raw target is deterministic and valid. *)
      check_head Request
        ("GET /"
        ^ Digest.to_hex (Digest.string wire)
        ^ " HTTP/1.1\r\nHost: x\r\n\r\n"));
  add "response" (fun wire ->
      let meth =
        if wire = "" then Method.get
        else
          List.nth
            [ Method.get; Method.head; Method.connect ]
            (Char.code wire.[0] mod 3)
      in
      check_head (Response meth) wire;
      check_head (Response Method.get)
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc");
  add "chunked" (fun wire ->
      check_chunks wire;
      (* Make body, terminator and trailer states reachable even when arbitrary
         bytes fail in the first chunk-size line. Empty payload has no data chunk. *)
      let payload = String.sub wire 0 (min 128 (String.length wire)) in
      let data =
        if payload = "" then ""
        else Printf.sprintf "%x;flag\r\n%s\r\n" (String.length payload) payload
      in
      check_chunks (data ^ "0\r\ndigest: generated\r\n\r\n"))
