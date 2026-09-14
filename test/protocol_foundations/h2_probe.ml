open Support

let consume reader body ~on_eof =
  let rec schedule () =
    H2.Body.Reader.schedule_read reader ~on_eof ~on_read:(fun bytes ~off ~len ->
        Buffer.add_string body (Bigstringaf.substring bytes ~off ~len);
        schedule ())
  in
  schedule ()

let exchange chunk =
  let answered = ref false and handled = ref 0 in
  let response = Buffer.create 64 in
  let config =
    {
      H2.Config.default with
      enable_server_push = false;
      max_concurrent_streams = 8l;
    }
  in
  let server =
    H2.Server_connection.create ~config (fun reqd ->
        incr handled;
        let request = H2.Reqd.request reqd in
        require (request.target = "/echo") "h2 target";
        let payload = Buffer.create 64 in
        consume (H2.Reqd.request_body reqd) payload ~on_eof:(fun () ->
            H2.Reqd.respond_with_string reqd
              (H2.Response.create
                 ~headers:
                   (H2.Headers.of_list
                      [
                        ("content-length", string_of_int (Buffer.length payload));
                      ])
                 `OK)
              (Buffer.contents payload)))
  in
  let error _ = failwith "unexpected h2 error" in
  let client = H2.Client_connection.create ~config ~error_handler:error () in
  let writer =
    H2.Client_connection.request client
      (H2.Request.create ~scheme:"https"
         ~headers:
           (H2.Headers.of_list
              [ (":authority", "localhost"); ("content-length", "5") ])
         `POST "/echo")
      ~error_handler:error
      ~response_handler:(fun reply reader ->
        require (reply.status = `OK) "h2 status";
        consume reader response ~on_eof:(fun () -> answered := true))
  in
  H2.Body.Writer.write_string writer "hello";
  H2.Body.Writer.close writer;
  let transfer operation report read =
    match operation () with
    | `Write iovecs ->
        let written = ref 0 in
        List.iter
          (fun (iov : Bigstringaf.t H2.IOVec.t) ->
            let pending = ref "" in
            fragments chunk
              (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len)
              (fun part ->
                let input = !pending ^ part in
                let bytes =
                  Bigstringaf.of_string ~off:0 ~len:(String.length input) input
                in
                let used = read bytes ~off:0 ~len:(String.length input) in
                pending := String.sub input used (String.length input - used));
            require (!pending = "") "h2 unconsumed probe bytes";
            written := !written + iov.len)
          iovecs;
        report (`Ok !written);
        !written > 0
    | `Yield | `Close _ -> false
  in
  let rec pump steps =
    require (steps < 1000) "h2 did not complete";
    let c =
      transfer
        (fun () -> H2.Client_connection.next_write_operation client)
        (H2.Client_connection.report_write_result client)
        (H2.Server_connection.read server)
    in
    let s =
      transfer
        (fun () -> H2.Server_connection.next_write_operation server)
        (H2.Server_connection.report_write_result server)
        (H2.Client_connection.read client)
    in
    if not !answered then (
      require (c || s) "h2 stalled";
      pump (steps + 1))
  in
  pump 0;
  require
    (!handled = 1 && Buffer.contents response = "hello")
    "h2 echo mismatch";
  H2.Client_connection.shutdown client;
  H2.Server_connection.shutdown server

let header_expansion () =
  (* Repeated indexed fields do not grow the dynamic table, but do grow the
     decoded list. This bounded probe establishes that table capacity is not
     a decoded-header admission limit. *)
  let encoder = Hpack.Encoder.create 4096 in
  let output = Faraday.create 256 in
  let header : Hpack.header =
    { name = "x-probe"; value = String.make 1024 'x'; sensitive = false }
  in
  for _ = 1 to 128 do
    Hpack.Encoder.encode_header encoder output header
  done;
  let wire = Faraday.serialize_to_string output in
  let decoded, allocated_bytes =
    allocated (fun () ->
        Angstrom.parse_string ~consume:All
          (Hpack.Decoder.decode_headers (Hpack.Decoder.create 4096))
          wire)
  in
  let fields =
    match decoded with
    | Ok (Ok fields) -> fields
    | _ -> failwith "HPACK fixture failed"
  in
  let bytes =
    List.fold_left
      (fun n (h : Hpack.header) ->
        n + String.length h.name + String.length h.value + 32)
      0 fields
  in
  require
    (List.length fields = 128 && bytes > 65536)
    "HPACK expansion control not exercised";
  `Assoc
    [
      ("wire_bytes", `Int (String.length wire));
      ("decoded_field_bytes", `Int bytes);
      ("allocated_bytes", `Float allocated_bytes);
      ("production_gate", `String "BLOCKED_NO_DECODED_HEADER_LIMIT");
    ]

let run () =
  List.iter exchange [ 1; 17; 16384 ];
  `Assoc
    [
      ("echo", `String "PASS");
      ("header_expansion", header_expansion ());
      ("production_ready", `Bool false);
    ]
