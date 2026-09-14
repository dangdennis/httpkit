open Httpkit_http1

let head =
  Framing_cases.request
    [ ("Transfer-Encoding", "chunked"); ("Trailer", "digest") ]

let meta = Http1_cases.chunk_meta

let valid =
  [
    ("empty", "0\r\n\r\n", "", []);
    ("leading-zero", "0003\r\nabc\r\n00\r\n\r\n", "abc", []);
    ("hex-uppercase", "A\r\n0123456789\r\n0\r\n\r\n", "0123456789", []);
    ( "extensions",
      "1;flag; name = token; quoted=\"a\\\"b\"\r\na\r\n0;done\r\n\r\n",
      "a",
      [] );
    ("multiple", "1\r\na\r\n2\r\nbc\r\n0\r\n\r\n", "abc", []);
    ( "declared-trailers",
      "1\r\na\r\n0\r\nDigest: first\r\ndigest: second\r\n\r\n",
      "a",
      [ ("digest", "first"); ("digest", "second") ] );
  ]

let invalid =
  [
    ("nonhex", "g\r\n", Invalid_chunk);
    ("signed", "-1\r\n", Invalid_chunk);
    ("hex-prefix", "0x1\r\n", Invalid_chunk);
    ("overflow", "8000000000000000\r\n", Invalid_chunk);
    ("trailing-space", "1 \r\n", Invalid_chunk);
    ("missing-extension", "1;\r\n", Invalid_chunk);
    ("missing-value", "1;x=\r\n", Invalid_chunk);
    ("unclosed-quote", "1;x=\"unterminated\r\n", Invalid_chunk);
    ("bad-data-cr", "1\r\naX\n", Invalid_chunk);
    ("bad-data-lf", "1\r\na\rX", Invalid_chunk);
    ("undeclared-trailer", "0\r\nx-new: value\r\n\r\n", Invalid_trailer);
    ("forbidden-trailer", "0\r\ncontent-length: 0\r\n\r\n", Invalid_trailer);
    ("folded-trailer", "0\r\n digest: value\r\n\r\n", Invalid_field);
  ]
