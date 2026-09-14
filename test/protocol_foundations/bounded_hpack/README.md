# Private bounded HPACK experiment

Derived from hpack 0.13.0 (António Nuno Monteiro, BSD-3-Clause). Each copied
source retains the upstream copyright, license and disclaimer. Tables and the
dynamic table implementation are unchanged. Decoder and Huffman output paths
are modified; the wrapper exposes only bounded whole-block decoding.

Limits cover input wire bytes, field count and decoded field bytes including
32 bytes of overhead per field. Integer continuation arithmetic is checked
before shifting/adding. Encoded literal length is checked before Angstrom.take;
Huffman output is checked before each emitted character. Header records and
dynamic-table insertion happen only after charging the field. Buffer capacity
can exceed logical output length by the standard Buffer growth factor; this is
a bounded-allocation experiment, not an exact allocator quota.

The decoded-string budget conservatively caps encoded literal length too. It
may reject Huffman encodings that fit the decoded budget but use more encoded
bytes. Table capacity is capped at 64 KiB. Failures poison the decoder: callers
must close the connection rather than reuse partially updated table state.

Not installed or integrated into h2. The caller already owns the complete input
string, so this cannot protect network buffering on its own. Streaming assembly,
CONTINUATION limits, cancellation, independent conformance and resource/performance
acceptance remain required. No second parser is put in front of upstream h2.
