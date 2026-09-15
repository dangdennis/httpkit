open Httpkit_core
module U = Httpkit.Url
module M = Httpkit.Multipart
module W = Httpkit.Websocket
module R = Httpkit_router
module S = Segmentation_support

let check = Crowbar.check

let schedules wire =
  let n = String.length wire in
  [ [ n ]; List.init n (( + ) 1); S.random_cuts n 7; S.random_cuts n 29 ]

let feed_chunks feed wire cuts =
  let window = S.window cuts (String.length wire) in
  let rec loop pos =
    if pos = String.length wire then Ok ()
    else
      let n = window pos in
      check (n > 0);
      match feed (String.sub wire pos n) with
      | Error _ -> Error ()
      | Ok () -> loop (pos + n)
  in
  loop 0

let url raw =
  let encoded = U.encode raw in
  let expected =
    if String.exists (fun c -> Char.code c < 32 || Char.code c = 127) raw then
      Error U.Invalid_byte
    else Ok raw
  in
  check (U.decode ~max_bytes:(String.length encoded) encoded = expected);
  (match U.decode ~max_bytes:2048 raw with
  | Error _ -> ()
  | Ok decoded -> check (String.length decoded <= String.length raw));
  match U.path_segments ~max_bytes:2048 raw with
  | Error _ -> ()
  | Ok segments ->
      List.iter
        (fun s ->
          check
            (s <> "." && s <> ".."
            && (not (String.contains s '/'))
            && not (String.contains s '\\')))
        segments

let forms raw =
  match U.pairs ~max_bytes:2048 ~max_fields:16 raw with
  | Error _ -> ()
  | Ok fields ->
      check (List.length fields <= 16);
      let encoded =
        String.concat "&"
          (List.map (fun (k, v) -> U.encode k ^ "=" ^ U.encode v) fields)
      in
      check
        (U.pairs ~max_bytes:(String.length encoded) ~max_fields:16 encoded
        = Ok fields);
      List.iter
        (fun (k, _) ->
          if List.length (List.filter (fun (key, _) -> key = k) fields) > 1 then
            check (U.unique k fields = Error U.Duplicate))
        fields

let router raw =
  let pattern = Result.get_ok (R.pattern "/p/:id/*rest") in
  let table =
    Result.get_ok
      (R.compile ~max_target_bytes:16384
         [ R.route ~meth:Method.get pattern () ])
  in
  let captured = "x" ^ U.encode raw in
  let target =
    Result.get_ok
      (Target.of_string ~max_length:16384
         ("/p/" ^ captured ^ "/tail?ignored=1"))
  in
  (match R.lookup table ~meth:Method.get ~target with
  | Ok (R.Matched m) ->
      check (R.Params.to_list m.params = [ ("id", captured); ("rest", "tail") ])
  | _ -> check false);
  check
    (R.lookup table ~meth:Method.post ~target
    = Ok (R.Method_not_allowed [ Method.get ]));
  (* Arbitrary valid core targets still obey the router's separate raw-target cap. *)
  match Target.of_string ~max_length:2048 raw with
  | Error _ -> ()
  | Ok target ->
      let bounded = Result.get_ok (R.compile ~max_target_bytes:32 []) in
      if String.length raw > 32 then
        check (R.lookup bounded ~meth:Method.get ~target = Error R.Target_limit)
      else ignore (R.lookup bounded ~meth:Method.get ~target)

let multipart wire cuts =
  let current = ref None and parts = ref [] and count = ref 0 in
  let parser =
    M.create ~boundary:"Aa" ~max_header_bytes:256 ~max_parts:4
      ~max_part_bytes:256 ~max_total_bytes:4096 (function
      | M.Begin p ->
          check (!current = None);
          incr count;
          check (!count <= 4);
          current := Some (p.name, p.filename, Buffer.create 32)
      | M.Data bytes -> (
          match !current with
          | None -> check false
          | Some (_, _, b) ->
              Buffer.add_string b bytes;
              check (Buffer.length b <= 256))
      | M.End -> (
          match !current with
          | None -> check false
          | Some (name, file, b) ->
              parts := (name, file, Buffer.contents b) :: !parts;
              current := None))
  in
  let feed bytes =
    let result = M.feed parser bytes in
    check (M.retained_bytes parser <= 259);
    result
  in
  match feed_chunks feed wire cuts with
  | Error () ->
      check (Result.is_error (M.feed parser "--Aa--\r\n"));
      check (M.retained_bytes parser = 0);
      Error ()
  | Ok () -> (
      match M.finish parser with
      | Error _ ->
          check (Result.is_error (M.feed parser "--Aa--\r\n"));
          Error ()
      | Ok () ->
          check (!current = None);
          Ok (List.rev !parts))

let check_multipart raw =
  let first = multipart raw [ String.length raw ] in
  List.iter (fun cuts -> check (multipart raw cuts = first)) (schedules raw);
  let payload =
    String.map
      (fun c -> if c = '-' then '_' else c)
      (String.sub raw 0 (min 128 (String.length raw)))
  in
  let wire =
    "--Aa\r\n\
     Content-Disposition: form-data; name=\"file\"; filename=\"../upload.txt\"\r\n\
     \r\n" ^ payload ^ "\r\n--Aa--\r\n"
  in
  List.iter
    (fun cuts ->
      check
        (multipart wire cuts = Ok [ ("file", Some "../upload.txt", payload) ]))
    (schedules wire)

let websocket wire cuts =
  let parser = W.server ~max_frame:256 ~max_message:256 () in
  let events = ref [] in
  let feed bytes =
    match W.feed parser bytes with
    | Error _ -> Error ()
    | Ok items ->
        events := List.rev_append items !events;
        Ok ()
  in
  match feed_chunks feed wire cuts with
  | Error () ->
      check (Result.is_error (W.feed parser ""));
      check (Result.is_error (W.eof parser));
      Error ()
  | Ok () -> (
      match W.eof parser with
      | Error _ ->
          check (Result.is_error (W.feed parser ""));
          Error ()
      | Ok () -> Ok (List.rev !events))

let masked op fin payload =
  let n = String.length payload in
  check (n < 126);
  String.make 1 (Char.chr ((if fin then 128 else 0) lor op))
  ^ String.make 1 (Char.chr (128 lor n))
  ^ "mask"
  ^ String.mapi
      (fun i c -> Char.chr (Char.code c lxor Char.code "mask".[i mod 4]))
      payload

let check_websocket raw =
  let first = websocket raw [ String.length raw ] in
  List.iter (fun cuts -> check (websocket raw cuts = first)) (schedules raw);
  let payload = String.sub raw 0 (min 120 (String.length raw)) in
  let split = String.length payload / 2 in
  let wire =
    masked 2 false (String.sub payload 0 split)
    ^ masked 9 true "ping"
    ^ masked 0 true (String.sub payload split (String.length payload - split))
    ^ masked 8 true ""
  in
  List.iter
    (fun cuts ->
      check
        (websocket wire cuts
        = Ok [ W.Ping "ping"; W.Binary payload; W.Close (None, "") ]))
    (schedules wire);
  List.iter
    (fun event -> check (Result.is_ok (W.encode event)))
    [ W.Binary payload; W.Ping "ping"; W.Close (None, "") ]

let () =
  let targets =
    [
      ("url", url);
      ("forms", forms);
      ("router", router);
      ("multipart", check_multipart);
      ("websocket", check_websocket);
    ]
  in
  let selected = Sys.getenv_opt "HTTP_KIT_FUZZ_CASE" in
  if
    not
      (Option.fold ~none:true
         ~some:(fun name -> List.mem_assoc name targets)
         selected)
  then invalid_arg "unknown web fuzz case";
  List.iter
    (fun (name, f) ->
      if selected = None || selected = Some name then
        Fuzz_input.add ~max_length:2048 ~name f)
    targets
