open Httpkit_http1

(* Authored from docs/http1.md's strict profile and RFC 9112 sections 6.1–6.3.
   Expectations are data, never sampled from the implementation under test. *)
let fields =
  let cl value = ("Content-Length", value)
  and te value = ("Transfer-Encoding", value) in
  [
    ("zero", [ cl "0" ], Ok (Fixed 0L));
    ("fixed", [ cl "3" ], Ok (Fixed 3L));
    ("leading-zero", [ cl "003" ], Ok (Fixed 3L));
    ("max-length", [ cl "9223372036854775807" ], Ok (Fixed Int64.max_int));
    ("duplicate-equal", [ cl "3"; cl "3" ], Error Ambiguous_framing);
    ("duplicate-conflicting", [ cl "3"; cl "4" ], Error Ambiguous_framing);
    ( "duplicate-case",
      [ cl "3"; ("cOnTeNt-LeNgTh", "3") ],
      Error Ambiguous_framing );
    ("comma-equal", [ cl "3, 3" ], Error Invalid_length);
    ("comma-conflicting", [ cl "3, 4" ], Error Invalid_length);
    ("empty-length", [ cl "" ], Error Invalid_length);
    ("negative-length", [ cl "-1" ], Error Invalid_length);
    ("positive-sign", [ cl "+3" ], Error Invalid_length);
    ("hex-length", [ cl "0x3" ], Error Invalid_length);
    ("decimal-overflow", [ cl "9223372036854775808" ], Error Invalid_length);
    ("embedded-space", [ cl "1 2" ], Error Invalid_length);
    ("chunked", [ te "chunked" ], Ok Chunked);
    ("chunked-case", [ te "ChUnKeD" ], Ok Chunked);
    ("cl-te", [ cl "3"; te "chunked" ], Error Ambiguous_framing);
    ("te-cl", [ te "chunked"; cl "3" ], Error Ambiguous_framing);
    ("zero-cl-te", [ cl "0"; te "chunked" ], Error Ambiguous_framing);
    ("duplicate-te", [ te "chunked"; te "chunked" ], Error Unsupported_coding);
    ("empty-te", [ te "" ], Error Unsupported_coding);
    ("identity", [ te "identity" ], Error Unsupported_coding);
    ("gzip", [ te "gzip" ], Error Unsupported_coding);
    ("coding-chain", [ te "gzip, chunked" ], Error Unsupported_coding);
    ("reversed-chain", [ te "chunked, gzip" ], Error Unsupported_coding);
    ("repeated-coding", [ te "chunked, chunked" ], Error Unsupported_coding);
    ("coding-parameter", [ te "chunked;x=y" ], Error Unsupported_coding);
    ("empty-list-member", [ te ",chunked" ], Error Unsupported_coding);
  ]

let wire_fields fields =
  String.concat "" (List.map (fun (k, v) -> k ^ ": " ^ v ^ "\r\n") fields)

let request fields =
  "POST / HTTP/1.1\r\nHost: x\r\n" ^ wire_fields fields ^ "\r\n"

let response fields = "HTTP/1.1 200 OK\r\n" ^ wire_fields fields ^ "\r\n"
