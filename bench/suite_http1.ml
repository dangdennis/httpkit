open Httpkit_core
open Suite_support
module H = Httpkit_http1

let decode_head ~step role wire =
  let decoder = H.head_decoder role in
  let rec loop offset =
    if offset = String.length wire then failwith "head did not complete";
    let n, metadata =
      ok
        (H.feed_head decoder wire ~off:offset
           ~len:(min step (String.length wire - offset)))
    in
    require (n > 0);
    match metadata with
    | Some metadata ->
        require (offset + n = String.length wire);
        metadata
    | None -> loop (offset + n)
  in
  loop 0

let body_work ~step metadata wire expected_bytes expected_trailers eof () =
  let decoder = H.body_decoder metadata in
  let offset = ref 0
  and total = ref 0
  and trailers = ref 0
  and ended = ref false in
  while not !ended do
    if !offset = String.length wire && eof then (
      require
        (ok ~error_to_string:H.error_to_string (H.eof_body decoder) = Some H.End);
      ended := true)
    else
      let n, event =
        ok
          (H.feed_body decoder wire ~off:!offset
             ~len:(min step (String.length wire - !offset)))
      in
      offset := !offset + n;
      match event with
      | Some (H.Data bytes) ->
          require (String.for_all (( = ) 'a') bytes);
          total := !total + String.length bytes
      | Some (H.Trailers fields) -> trailers := Headers.length fields
      | Some H.End -> ended := true
      | None -> require (n > 0)
  done;
  require
    (!offset = String.length wire
    && !total = expected_bytes
    && !trailers = expected_trailers)

let jobs () =
  let heads =
    List.concat_map
      (fun fields ->
        let suffix =
          String.concat ""
            (List.init fields (fun _ -> "X-Value: abcdefghijklmnop\r\n"))
          ^ "\r\n"
        in
        List.concat_map
          (fun step ->
            List.map
              (fun (name, role, prefix) ->
                let wire = prefix ^ suffix in
                job ~bytes:(String.length wire) "http1"
                  (Printf.sprintf "head/%s/fields-%d/step-%d" name fields step)
                  100 (fun () ->
                    let metadata = decode_head ~step role wire in
                    match metadata.head with
                    | H.Request_head r ->
                        require (Headers.length (Request.headers r) = fields + 1)
                    | H.Response_head r ->
                        require (Headers.length (Response.headers r) = fields)))
              [
                ("request", H.Request, "GET / HTTP/1.1\r\nHost: x\r\n");
                ("response", H.Response Method.get, "HTTP/1.1 200 OK\r\n");
              ])
          [ 1; 64; 16384 ])
      [ 0; 10; 90 ]
  in
  let bodies =
    List.concat_map
      (fun size ->
        let body = String.make size 'a' in
        let fixed_head =
          Printf.sprintf
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" size
        in
        let fixed = decode_head ~step:16384 H.Request fixed_head in
        let chunked =
          decode_head ~step:16384 H.Request
            "POST / HTTP/1.1\r\n\
             Host: x\r\n\
             Transfer-Encoding: chunked\r\n\
             Trailer: x-check\r\n\
             \r\n"
        in
        let close =
          decode_head ~step:16384 (H.Response Method.get)
            "HTTP/1.1 200 OK\r\n\r\n"
        in
        let chunkwire =
          Printf.sprintf "%x\r\n%s\r\n0\r\nx-check: yes\r\n\r\n" size body
        in
        List.concat_map
          (fun step ->
            List.map
              (fun (name, metadata, wire, trailers, eof) ->
                job ~bytes:size "http1"
                  (Printf.sprintf "body/%s/bytes-%d/step-%d" name size step)
                  (if step = 1 then 2 else 30)
                  (body_work ~step metadata wire size trailers eof))
              [
                ("fixed", fixed, body, 0, false);
                ("chunked-trailers", chunked, chunkwire, 1, false);
                ("close-delimited", close, body, 0, true);
              ])
          [ 1; 64; 16384 ])
      [ 64; 4096; 65536 ]
  in
  let reject =
    List.map
      (fun (name, wire, error) ->
        job ~bytes:(String.length wire) "http1" ("reject/" ^ name) 1000
          (fun () ->
            let decoder = H.head_decoder H.Request in
            require
              (H.feed_head decoder wire ~off:0 ~len:(String.length wire)
              = Error error)))
      [
        ( "invalid-version",
          "GET / HTTP/9.9\r\nHost: x\r\n\r\n",
          H.Unsupported_version );
        ( "invalid-field",
          "GET / HTTP/1.1\r\nHost: x\r\nBad Header: x\r\n\r\n",
          H.Invalid_field );
      ]
  in
  let truncated = "GET / HTTP/1.1\r\nHost: x\r\n" in
  let eof =
    job "http1" "reject/truncated-eof" 1000 (fun () ->
        let decoder = H.head_decoder H.Request in
        let n, m =
          ok
            (H.feed_head decoder truncated ~off:0 ~len:(String.length truncated))
        in
        require
          (n = String.length truncated
          && m = None
          && H.eof_head decoder = Error H.Unexpected_eof))
  in
  let headers =
    ok (Headers.of_list [ ("host", "x"); ("content-length", "0") ])
  in
  let request =
    Request.create ~meth:Method.post
      ~target:(ok (Target.of_string "/"))
      ~headers ()
  in
  let response =
    Response.create ~status:Status.ok
      ~headers:(ok (Headers.of_list [ ("content-length", "0") ]))
      ()
  in
  let encode =
    [
      job "http1" "encode/request-head" 3000 (fun () ->
          let wire, _ =
            ok ~error_to_string:H.error_to_string (H.encode_request request)
          in
          require
            (wire = "POST / HTTP/1.1\r\nhost: x\r\ncontent-length: 0\r\n\r\n"));
      job "http1" "encode/response-head" 3000 (fun () ->
          let wire, _ =
            ok ~error_to_string:H.error_to_string
              (H.encode_response ~request_method:Method.get response)
          in
          require (wire = "HTTP/1.1 200 \r\ncontent-length: 0\r\n\r\n"));
    ]
  in
  let encode_bodies =
    List.concat_map
      (fun size ->
        let body = String.make size 'a' in
        List.map
          (fun chunked ->
            let headers =
              if chunked then [ ("transfer-encoding", "chunked") ]
              else [ ("content-length", string_of_int size) ]
            in
            let response =
              Response.create ~status:Status.ok
                ~headers:(ok (Headers.of_list headers))
                ()
            in
            let _, metadata =
              ok ~error_to_string:H.error_to_string
                (H.encode_response ~request_method:Method.get response)
            in
            let expected =
              if chunked then Printf.sprintf "%x\r\n%s\r\n" size body else body
            in
            job ~bytes:size "http1"
              (Printf.sprintf "encode/%s-body/bytes-%d"
                 (if chunked then "chunked" else "fixed")
                 size)
              1000
              (fun () ->
                let encoder = H.body_encoder metadata in
                require
                  (ok ~error_to_string:H.error_to_string
                     (H.encode_data encoder body)
                  = expected);
                require
                  (ok ~error_to_string:H.error_to_string (H.finish_body encoder)
                  = if chunked then "0\r\n\r\n" else "")))
          [ false; true ])
      [ 64; 4096; 16384 ]
  in
  let token_membership =
    List.map
      (fun count ->
        let tokens name = String.concat "," (List.init count (fun _ -> name)) in
        let wire =
          "POST / HTTP/1.1\r\n\
           Host: x\r\n\
           Transfer-Encoding: chunked\r\n\
           Connection: " ^ tokens "x" ^ "\r\nTrailer: " ^ tokens "y"
          ^ "\r\n\r\n"
        in
        job ~bytes:(String.length wire) "http1"
          (Printf.sprintf "head/token-membership/%d" count) 100 (fun () ->
            let metadata = decode_head ~step:16384 H.Request wire in
            require ~message:"token fixture framing changed"
              (metadata.framing = H.Chunked)))
      [ 10; 100; 1000; 3000 ]
  in
  heads @ bodies @ reject @ [ eof ] @ encode @ encode_bodies @ token_membership
