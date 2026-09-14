open Support
module H = Bounded_hpack

let encode encoder fields =
  let out = Faraday.create 128 in
  List.iter (Hpack.Encoder.encode_header encoder out) fields;
  Faraday.serialize_to_string out

let limits = H.{ max_wire = 8192; max_fields = 32; max_bytes = 4096 }
let create ?(limits = limits) () = H.create ~table_capacity:4096 limits
let header value : Hpack.header = { name = "x-test"; value; sensitive = false }

let run () =
  let encoder = Hpack.Encoder.create 4096 in
  let wire = encode encoder [ header "hello" ] in
  let decoder = create () in
  let first = H.decode decoder wire in
  require (Result.is_ok first) "bounded HPACK positive";
  let indexed = encode encoder [ header "hello" ] in
  require (H.decode decoder indexed = first) "HPACK cross-block table reuse";
  let rejection name limits wire =
    let decoder = create ~limits () in
    require (Result.is_error (H.decode decoder wire)) name;
    require (Result.is_error (H.decode decoder "")) (name ^ " not terminal")
  in
  rejection "wire budget" { limits with max_wire = 0 } wire;
  rejection "field budget" { limits with max_fields = 0 } wire;
  rejection "byte budget" { limits with max_bytes = 32 } wire;
  let repeated =
    encode
      (Hpack.Encoder.create 4096)
      (List.init 128 (fun _ -> header (String.make 1024 'x')))
  in
  rejection "indexed expansion" limits repeated;
  rejection "integer overflow" limits ("\255" ^ String.make 20 '\255' ^ "\000");
  (* Literal without indexing, name x, raw value length 127 + 127 = 254;
     no value bytes are supplied: length must be rejected before take. *)
  let oversized = "\000\001x\127\127" in
  let decoder = create ~limits:{ limits with max_bytes = 64 } () in
  (match H.decode decoder oversized with
  | Error reason ->
      require
        (String.ends_with ~suffix:"HPACK encoded literal budget" reason)
        ("literal was buffered instead of rejected: " ^ reason)
  | Ok _ -> failwith "oversized literal accepted");
  for len = 1 to String.length wire - 1 do
    rejection "truncation" limits (String.sub wire 0 len)
  done;
  require
    (H.decode
       (create ~limits:{ limits with max_bytes = 43; max_fields = 1 } ())
       wire
    = first)
    "exact decoded budget";
  rejection "decoded one byte over" { limits with max_bytes = 42 } wire;
  let static = String.make 32 '\130' in
  require (Result.is_ok (H.decode (create ()) static)) "exact field count";
  rejection "one excess indexed field" limits (static ^ "\130");
  let large_huffman =
    encode (Hpack.Encoder.create 4096) [ header (String.make 100 'a') ]
  in
  rejection "Huffman output budget"
    { limits with max_bytes = 118 }
    large_huffman;
  require
    (Result.is_ok
       (H.decode
          (create ~limits:{ limits with max_bytes = 138 } ())
          large_huffman))
    "Huffman exact output budget";
  rejection "zero index" limits "\128";
  rejection "invalid Huffman padding" limits "\000\001x\129\000";
  let literal = "\000\001x\001y" in
  require
    (Result.is_ok
       (H.decode (create ~limits:{ limits with max_bytes = 34 } ()) literal))
    "raw literal exact budget";
  `Assoc
    [
      ("status", `String "PASS");
      ("production_ready", `Bool false);
      ("scope", `String "WHOLE_BLOCK_CORE_ONLY");
    ]
