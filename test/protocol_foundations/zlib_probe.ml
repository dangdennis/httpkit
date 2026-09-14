open Support
module B = Bytesrw.Bytes

(* A bounded fixture collector, not a production adapter. The input budget also
   bounds work spent skipping optional headers that produce no output. *)
type failure = Input_limit | Output_limit | Malformed

exception Budget of failure

let upstream ~slice_length source =
  (Bytesrw_zlib.Gzip.decompress_reads () ~slice_length source, Fun.id)

let decode ?(reader_factory = upstream) ~input_chunk ~output_chunk ~input_limit
    ~output_limit wire =
  let bytes = Bytes.of_string wire in
  let offset = ref 0 and total = ref 0 in
  let source =
    B.Reader.make ~slice_length:input_chunk (fun () ->
        if !offset = Bytes.length bytes then B.Slice.eod
        else if !offset = input_limit then raise (Budget Input_limit)
        else
          let length =
            min input_chunk
              (min (Bytes.length bytes - !offset) (input_limit - !offset))
          in
          let slice = B.Slice.make bytes ~first:!offset ~length in
          offset := !offset + length;
          slice)
  in
  let reader, close = reader_factory ~slice_length:output_chunk source in
  let output = Buffer.create (min output_limit 4096) in
  let rec loop () =
    let slice = B.Reader.read reader in
    let length = B.Slice.length slice in
    if length = 0 then Ok (Buffer.contents output)
    else if length > output_limit - !total then Error Output_limit
    else (
      total := !total + length;
      Buffer.add_string output (B.Slice.to_string slice);
      loop ())
  in
  Fun.protect ~finally:close (fun () ->
      try loop () with
      | Budget reason -> Error reason
      | B.Stream.Error _ -> Error Malformed)

let with_header wire flags optional =
  let header = Bytes.of_string (String.sub wire 0 10) in
  Bytes.set header 3 (Char.chr flags);
  Bytes.to_string header ^ optional
  ^ String.sub wire 10 (String.length wire - 10)

let damage wire index =
  let bytes = Bytes.of_string wire in
  Bytes.set bytes index (Char.chr (Char.code (Bytes.get bytes index) lxor 1));
  Bytes.to_string bytes

let run ?(reader_factory = upstream) () =
  let decode = decode ~reader_factory in
  let wire = read "fixtures/payload.gz"
  and payload = read "fixtures/payload.txt" in
  let fixtures =
    [
      ("plain", wire);
      ("filename", with_header wire 8 "fixture.txt\000");
      ("comment", with_header wire 16 "fixture comment\000");
      ("extra", with_header wire 4 "\004\000abcd");
      ("combined", with_header wire 28 "\004\000abcdfixture.txt\000comment\000");
    ]
  in
  let check input_chunk output_chunk =
    let decode =
      decode ~input_chunk ~output_chunk ~input_limit:65536 ~output_limit:100000
    in
    List.iter
      (fun (name, fixture) ->
        require
          (decode fixture = Ok payload)
          (Printf.sprintf "zlib %s input=%d output=%d" name input_chunk
             output_chunk))
      fixtures;
    require (decode (damage wire 0) = Error Malformed) "zlib magic rejection";
    require (decode (damage wire 2) = Error Malformed) "zlib method rejection";
    require
      (decode (with_header wire 32 "") = Error Malformed)
      "zlib reserved flags rejection";
    require
      (decode (with_header (String.sub wire 0 10) 8 (String.make 32 'x'))
      = Error Malformed)
      "zlib unterminated filename rejection";
    require (decode (wire ^ wire) = Ok (payload ^ payload)) "zlib concatenation";
    require (decode (wire ^ "trailing") = Error Malformed) "zlib trailing bytes";
    require
      (decode (damage wire (String.length wire - 8)) = Error Malformed)
      "zlib CRC rejection";
    require
      (decode (damage wire (String.length wire - 4)) = Error Malformed)
      "zlib size rejection";
    (* Every proper prefix must fail, including optional-header boundaries. *)
    List.iter
      (fun (name, fixture) ->
        for length = 0 to String.length fixture - 1 do
          require
            (decode (String.sub fixture 0 length) = Error Malformed)
            (Printf.sprintf "zlib truncated %s at %d" name length)
        done)
      fixtures
  in
  List.iter (fun i -> List.iter (check i) [ 1; 128; 4096 ]) [ 1; 10; 17; 4096 ];
  let bounded = decode ~input_chunk:17 ~output_chunk:128 in
  require
    (bounded ~input_limit:65536 ~output_limit:32 wire = Error Output_limit)
    "zlib output budget";
  require
    (bounded ~input_limit:65536 ~output_limit:(String.length payload) wire
    = Ok payload)
    "zlib exact output budget";
  require
    (bounded ~input_limit:(String.length wire) ~output_limit:65536 wire
    = Ok payload)
    "zlib exact input budget";
  let long_header = with_header wire 8 (String.make 8192 'x' ^ "\000") in
  require
    (bounded ~input_limit:1024 ~output_limit:65536 long_header
    = Error Input_limit)
    "zlib optional header budget";
  let _, allocation =
    allocated (fun () -> bounded ~input_limit:65536 ~output_limit:65536 wire)
  in
  `Assoc
    [
      ("status", `String "PASS");
      ("bytesrw_version", `String "0.4.0");
      ("zlib_version", `String (Bytesrw_zlib.version ()));
      ("fragmentation_combinations", `Int 12);
      ("optional_header_variants", `Int 4);
      ("decode_allocated_bytes", `Float allocation);
      ("production_ready", `Bool false);
      ( "remaining_gate",
        `String "EARLY_ABORT_NATIVE_CLEANUP_AND_RUNTIME_CANCELLATION" );
    ]
