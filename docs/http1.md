# HTTP/1 codec policy and ownership

Implemented in `httpkit-http1`, using core values and the pure ipaddr library for IPv6 authorities. The public interface is `lib/http1/httpkit_http1.mli`. The implementation is a byte-scanning state machine: each accepted byte is scanned once for delimiters, with bounded line parsing at a delimiter. There is no speculative backtracking or repeated scanning of an accumulated head on every incoming byte.

## Incremental ownership

`feed_head` and `feed_body` take `string`, `off`, and `len`, checking slice arithmetic before access. A successful call returns its consumed prefix; the caller retains every unconsumed byte. Calls may stop at the configured work budget even without an event. The codec never reads more input itself.

A head is published only after its full syntax and framing/authority checks pass. An error is terminal and publishes no metadata. Since an error invalidates the exchange, its offered input is never eligible to become a new request. The owning engine must close or abort, rather than retry that suffix with a fresh decoder.

Body calls emit at most one owned immutable data chunk, trailer collection, or End. Empty data/input is not end. Poll again after the last data, including with empty input, to observe End. EOF has a separate API and fails incomplete fixed/chunked framing. Close-delimited responses finish at EOF and cannot be reused. Tunnel bodies consume no bytes; request association and authorization of a tunnel belong to the engine.

## Strict profile

Normative references: [request targets](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2), [message length](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3), and [chunking](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1). The following strictness choices include deliberate rejection where the RFC permits recovery:

- HTTP/1.1 only. Reject HTTP/1.0, bare LF, obsolete folding, extra start-line separators, whitespace before colons, control bytes, and invalid reason text.
- Exactly one request Host. Origin, asterisk, absolute, and CONNECT authority forms are checked with originating method context. Absolute/CONNECT authority must agree with Host, including scheme-default ports. Host labels are ASCII letters, digits, and hyphens separated by dots, without empty labels or leading/trailing hyphens; bracketed IPv6 uses ipaddr. Userinfo, encoded hosts, and empty ports are rejected. There is no DNS resolution or application trust inference.
- Reject duplicate Content-Length (even equal), comma lists, signs, junk, and decimal overflow. Accept leading zeros. Reject CL with TE, multiple transfer-coding fields, and every coding chain except a single case-insensitive `chunked`.
- Honor HEAD/304 bodylessness with representation length metadata. Reject length/transfer-coding fields on informational and 204 responses and successful tunnel responses under this profile. A normal response without explicit length is close-delimited.
- Parse bounded hexadecimal chunk sizes, token/quoted extensions, chunk CRLF, and trailer termination. Check every size before arithmetic or integer conversion. Empty data passed to an encoder never emits a terminal chunk.
- Require declared trailer names and reject framing, routing, authentication, representation-interpretation, and connection-control fields. The exact forbidden list is kept beside the validator. Trailers never merge into initial headers.
- Reject unsupported request expectations; represent `100-continue` explicitly for the engine. Connection and informational response sequencing are engine responsibilities.

## Limits and output

Defaults are 8 KiB per start/field line, 32 KiB for a head, 100 fields, 16 KiB/64 fields for trailers, 1 KiB per chunk-size/extension line, and 16 KiB per input/data operation. An optional int64 total-body quota is checked without allocating advertised lengths. Limits are constructor-validated and configurable.

These bounds count logical input/field bytes, not total RSS. The line Buffer can retain up to roughly twice its logical bound; parsed strings and metadata add linear overhead. The decoder holds at most one head/trailer section and emits body chunks directly to its caller. The caller is responsible for any data it retains after an event.

Head encoding shares semantic checks with decoding, validates before returning bytes, preserves field order, and emits canonical lowercase names and colon/SP separators. Canonicalization can require slightly more space than a compact accepted wire field; encoding may therefore reject at a configured size bound. Response reason phrases are empty. No length is inferred from an arbitrary body value.

Body encoders enforce exact fixed length, chunk framing, declared trailers, and exactly one finish. After any encoder failure, the exchange must abort; a caller cannot insert a second HTTP response into a body already sent.

## Evidence

`test/http1` contains golden syntax/framing cases, all single split points for golden heads and selected bodies, EOF prefixes, malformed framing followed by a marker request, exact quotas, encoder misuse, and a generated fixed-body fragmentation property. The public installed consumer runs in bytecode and native modes; the independent http/af response parser checks the emitted chunked response and duplicate Set-Cookie order.

`fuzz/http1_fuzz.ml` checks one-byte versus whole-input request/response/chunked behavior. Accepted heads are re-encoded and decoded. The smoke runner uses valid seeds, preserves findings, and replays queue entries without instrumentation. `bench/http1_bench.ml` measures head time/allocation at geometric field sizes with one-byte and whole-buffer delivery. Stable-runner thresholds, reference disagreements beyond this initial lane, and long release campaigns remain later gates.

Head scanning is linear in input bytes. Connection/trailer token validation uses
a deterministic balanced set rather than repeated list scans. For C Connection
and T Trailer tokens it takes O((C + T) log(C + 1)) name comparisons, each bounded
by the compared name lengths. Header byte limits also bound the retained index.

### Explicit framing matrix

`test/http1/framing_cases.ml` is authored policy data derived from the strict
profile above and RFC 9112 sections 6.1–6.3. It does not learn expected outcomes
from a baseline parser run. `test/engine/framing_test.ml` applies it to request and
response decoders, both encoders, and server rejection isolation.

| Cases | Expected policy |
| --- | --- |
| Zero, positive, leading-zero, largest int64 CL | Fixed length |
| Equal/conflicting/case-varied duplicate CL | Ambiguous framing |
| Comma CL, empty/signed/hex/overflow/internal-space CL | Invalid length |
| One case-insensitive chunked TE | Chunked |
| CL with chunked TE in either order, including zero CL | Ambiguous framing |
| Duplicate/empty TE, identity, gzip, chains, parameters, empty list member | Unsupported coding |

Every wire case runs whole, bytewise, at each split and deterministic random
splits with work budgets 1, 7 and 16384. Rejected server heads must emit only one
Closed event, preserve the protocol failure across abort, release queues and
reject a following valid request. These cases do not close the broader smuggling,
special-response, client sequencing or real-proxy acceptance campaigns.

`test/http1/chunk_cases.ml` and `test/engine/chunk_test.ml` add explicit valid
extension/trailer outcomes, malformed chunk/terminator/trailer rejection, exact
and cumulative body quotas, and huge declared chunks without payload allocation.
Normal and discard-mode engines must close on every malformed-body fixture and
refuse an appended request under every segmentation/work schedule.
