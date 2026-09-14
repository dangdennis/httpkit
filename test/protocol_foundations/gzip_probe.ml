open Support

(* This is a feasibility probe, not the production compression wrapper. *)
let decode ~input_chunk ~output_chunk ~limit wire =
  let out = Bigstringaf.create output_chunk in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  let offset = ref 0 and total = ref 0 and steps = ref 0 in
  let output = Buffer.create (min limit 4096) in
  let drain d =
    let len = output_chunk - Gz.Inf.dst_rem d in
    if len > limit - !total then Error "output limit"
    else (
      total := !total + len;
      Buffer.add_string output (Bigstringaf.substring out ~off:0 ~len);
      Ok ())
  in
  let rec loop d =
    incr steps;
    require (!steps < 100000) "gzip probe did not terminate";
    match Gz.Inf.decode d with
    | `Malformed reason ->
        Error
          (Printf.sprintf "%s (fed=%d decoded=%d remaining=%d)" reason !offset
             !total (Gz.Inf.src_rem d))
    | `Await d ->
        let remaining = max 0 (Gz.Inf.src_rem d) in
        let len = min input_chunk (String.length wire - !offset) in
        let d =
          if len = 0 then Gz.Inf.src d input 0 0
          else Gz.Inf.src d input (!offset - remaining) (remaining + len)
        in
        offset := !offset + len;
        loop d
    | `Flush d -> (
        match drain d with Error e -> Error e | Ok () -> loop (Gz.Inf.flush d))
    | `End d -> (
        match drain d with
        | Error e -> Error e
        | Ok () -> Ok (Buffer.contents output))
  in
  loop (Gz.Inf.decoder `Manual ~o:out)

let run () =
  let wire = read "fixtures/payload.gz"
  and payload = read "fixtures/payload.txt" in
  List.iter
    (fun input_chunk ->
      List.iter
        (fun output_chunk ->
          match decode ~input_chunk ~output_chunk ~limit:65536 wire with
          | Ok actual ->
              require (actual = payload)
                (Printf.sprintf
                   "gzip bytes: input=%d output=%d actual=%d expected=%d"
                   input_chunk output_chunk (String.length actual)
                   (String.length payload))
          | Error error ->
              failwith
                (Printf.sprintf "gzip: input=%d output=%d: %s" input_chunk
                   output_chunk error))
        [ 128; 4096 ])
    [ 4096; 17 ];
  let single_byte =
    match decode ~input_chunk:1 ~output_chunk:128 ~limit:65536 wire with
    | Ok actual when actual = payload -> "PASS"
    | Ok _ -> failwith "single-byte gzip corrupted output"
    | Error reason ->
        require
          (reason = "Unexpected end of input (fed=10 decoded=0 remaining=10)")
          ("New single-byte gzip failure: " ^ reason);
        reason
  in
  require
    (decode ~input_chunk:17 ~output_chunk:128 ~limit:32 wire
    = Error "output limit")
    "gzip quota bypass";
  let truncated = String.sub wire 0 (String.length wire - 4) in
  require
    (Result.is_error
       (decode ~input_chunk:17 ~output_chunk:128 ~limit:65536 truncated))
    "gzip truncation accepted";
  let damaged = Bytes.of_string wire in
  let crc = Bytes.length damaged - 8 in
  Bytes.set damaged crc (Char.chr (Char.code (Bytes.get damaged crc) lxor 1));
  require
    (Result.is_error
       (decode ~input_chunk:17 ~output_chunk:128 ~limit:65536
          (Bytes.to_string damaged)))
    "gzip checksum accepted";
  let _, allocation =
    allocated (fun () ->
        decode ~input_chunk:17 ~output_chunk:4096 ~limit:65536 wire)
  in
  `Assoc
    [
      ("status", `String (if single_byte = "PASS" then "PASS" else "PARTIAL"));
      ("single_byte_input", `String single_byte);
      ("payload_bytes", `Int (String.length payload));
      ("decode_allocated_bytes", `Float allocation);
      ("production_ready", `Bool false);
    ]
