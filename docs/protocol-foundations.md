# Protocol foundations: first implementation slice

Phase 0 of the [library plan](protocol-libraries-plan.md) is in progress. The
private experiments are executable; no new production package is exposed yet.
Existing HTTP/1 APIs and production dependency closures are unchanged.

## Run and interpret the experiments

```sh
tools/dev protocol-spikes
tools/dune-pkg runtest test/protocol_foundations --force
```

The first command builds and runs native and ordinary bytecode programs under
the locked environment and writes `_artifacts/protocol-foundations/report.json`.
Dune supplies the C-stub search paths for bytecode; no custom embedded runtime is
required. The second runs the same assertions as part of the regression suite.
`EXPERIMENTS_COMPLETE` means the probes ran successfully, not that the dependencies
are approved for production. The report deliberately says `production_gate:
NOT_READY`. Allocations are single-run diagnostics, not performance acceptance.
AFL is skipped.

The baseline at `a0b64f5` passed the full local `tools/dev validate` matrix before
source edits. Its source hash is
`ec748105a4e389cd1cd1df1eeb2a20cb583b8779c02cf5705d7d51d6d9f3d1ee`.
Baseline logs are retained under `_artifacts/protocol-foundations/`; historical
load/coverage evidence is not relabeled as evidence for these new experiments.

## Dependency decisions so far

Exact versions are pinned only in the development harness and in both ordinary
and coverage locks. Production applications do not acquire TLS, HTTP/2 or gzip
through this experiment. The initial three roots added five locked packages: `h2`,
`hpack`, `tls`, `decompress`, and `checkseum`; existing dependencies satisfy the rest.
The lock refresh did not change existing package versions.

| Candidate | License in pinned source | Current result | Production decision |
| --- | --- | --- | --- |
| `tls` 2.1.2 | BSD-2-Clause | Fragmented handshake, ALPN, application data and close; rejects wrong hostname and unknown CA | Continue integration review; runtime limits/cancellation still unproved |
| `h2` / `hpack` 0.13.0 | BSD-3-Clause, with upstream notices | Fragmented request/body/response exchange passes; decoded header limit gap reproduced | Block production adoption until bounded decoding is available |
| `decompress` 1.6.0 | MIT | Larger fragments, output quota, truncation and checksum controls pass; gzip header-boundary failure reproduced | Block production adapter until corrected or replaced |

Upstream references: [ocaml-tls](https://github.com/mirleft/ocaml-tls),
[ocaml-h2](https://github.com/anmonteiro/ocaml-h2), and
[decompress](https://github.com/mirage/decompress). The pinned repository contains
these releases. This is not a claim that a full advisory or maintenance audit
has been completed. TLS and gzip sources record 2026 releases; the h2 source
changelog records 0.13.0 on 2024-09-04. Review current advisories, unreleased fixes,
maintenance and supported platforms before committing to a production dependency.

Native boundaries already present in the dependency closure include bigstring,
crypto, arithmetic and checksum stubs. TLS uses upstream cryptography and X.509;
this project adds no crypto algorithms or certificate validation implementation.
The fixture key is public test data, never a service credential.

## HTTP/2: the header table is not a decoded-header limit

`test/protocol_foundations/h2_probe.ml` tests fragmented in-memory echo exchanges
at 1, 17 and 16384-byte transport slices. It separately encodes 128 repeated fields
with a 4096-byte HPACK dynamic table and decodes them through the upstream API.
The fixture is only 1034 wire bytes but represents 136064 decoded field bytes
including the per-field accounting overhead. This is a bounded diagnostic, not
an unbounded stress test or a claimed vulnerability exploit.

The upstream `H2.Config` interface exposes frame/body buffers and stream/window
settings, but not decoded-header byte/count limits. `Hpack.Decoder.decode_headers`
returns the entire list. `SETTINGS_MAX_HEADER_LIST_SIZE` in the settings type is
not an enforced local allocation budget. A check after converting the list into
`Httpkit_core.Headers` is too late to protect the decoder's allocations.

Next action: evaluate an upstream-compatible decoder change that accounts for
fields, string lengths, Huffman output, integer overflow and CONTINUATION work
before allocation. Include oversized literal and many-indexed-field tests and
verify that rejected streams/headers leave connection state valid or close it.
Do not add a second independent HPACK parser in front of the backend. If the API
cannot support this, reconsider the backend and re-estimate the phase.

## Gzip: header-boundary refill failure

`gzip_probe.ml` retains unconsumed input reported by `Gz.Inf.src_rem` before
refilling. The independent `gzip -n` fixture expands to 36864 bytes. 17-byte and
whole-input feeds work with 128-byte and 4096-byte output buffers. The output
quota is checked before copying decoder output into the collector; the collector
exists only to verify this bounded fixture, not as a proposed streaming API.

With one-byte input, decoding reaches the end of the ten-byte gzip header and
fails with `Unexpected end of input` before producing any payload. Source review
of `Gz.Inf.header`/`kfinal` shows that it constructs the DEFLATE decoder and feeds
the remaining slice, whose length can be zero at exactly that boundary. A
zero-length manual DEFLATE feed signals EOF. This must be fixed at the transition
or avoided by a rigorously bounded adapter strategy covering optional gzip
headers too; merely raising the test fragment size is not a fix.

The report retains the one-byte result as an open compatibility gate. Additional
review found dynamically accumulated gzip filename/comment fields, which require
an explicit compressed/header-input budget before a production decoder can be
considered bounded. Bytesrw/native zlib is now tested by the alternative probe below. No upstream patch has been sent.

## TLS: verified core behavior, runtime work remains

`tls_probe.ml` uses a local test trust anchor and a fixed validation date, never
an accept-all authenticator. It exercises one-byte fragmentation, negotiated
`h2`, encrypted application data and `close_notify`, and rejects a wrong host
and an untrusted certificate. Cryptographic operations, randomness and identity
verification are entirely upstream.

Still required: Eio/Lwt handshake admission, cancellation and shutdown; maximum
handshake work/bytes; oversized certificate chains; expiry and ALPN mismatch;
independent peers; trust-store/revocation policy; and native-memory accounting.
The small core handshake probe does not establish these properties.

## Metadata seam and ownership proposal

`metadata.ml` / `metadata.mli` are private prototypes. They preserve the current
HTTP/1 version default, methods and raw targets, and separate HTTP/2 scheme and
authority from ordinary fields. A regression checks duplicate field order and
that HTTP/2 is represented as HTTP/2 rather than masquerading as HTTP/1.1.

Backend validation of pseudo-headers, authority consistency, CONNECT forms and
framing remains required. The conversion is deliberately not a public validator.
It handles ordinary requests only; CONNECT needs a distinct constructor/profile.
No constructors are added to the public HTTP/1 version type in this slice.

The eventual backend contract should expose connection-owned opaque stream
handles, metadata and bounded body/trailer events, explicit output credits,
accepted-versus-backpressured commands, stream reset, and connection shutdown.
Each runtime retains its native cancellation model. Credit is replenished only
when the application consumes or safely discards data; no backend may retain an
unbounded body while a handler is suspended. Public interfaces await resolution
of the decoder gates rather than embedding an unsafe assumption now.

## Threat model and remaining Phase 0 gates

Peers control framing, compressed bytes, header fields, stream churn and timing.
Applications can cancel at any read/write boundary or stop consuming a body.
Critical invariants are pre-allocation bounds, monotonic work/deadline budgets,
connection-versus-stream error separation, single resource ownership, and cleanup
that preserves the original failure. Crypto state and mutable stream state must
not cross domains without an explicitly supported upstream contract.

Before Phase 0 is complete: resolve the two decoder gates; compare the alternative
codec; finish advisory/license/native-memory review; validate runtime cancellation;
run isolated installed consumers and stable performance/resource measurements;
repeat relevant checks under both lock profiles and on macOS/Linux. Record exactly
which gates passed in artifacts. Full protocol conformance, hosted CI, independent
security review and sustained load remain separate later acceptance work.

## Gzip alternative: Bytesrw 0.4.0 with native zlib

The development harness now also pins `bytesrw` 0.4.0 and requires `conf-zlib`;
only `bytesrw.zlib` is linked by the new probe. Both lock profiles enable zlib
and disable Bytesrw's optional crypto, TLS and other codec bindings. The system
zlib version is reported at runtime: the opam lock does not pin that native
library. The release archive checksum matches the opam source checksum.

`zlib_probe.ml` checks twelve input/output fragment combinations, including
one-byte reads and writes. It covers filename, comment, extra and combined gzip
headers; concatenated members; trailing garbage; invalid magic, method and flags;
CRC and size corruption; and every proper prefix of all five fixtures. It also
checks exact input/output budget boundaries and rejection of a long optional
header before it can consume the full source. Output is checked before copying
into the fixture collector; the decoder itself may produce one bounded output
slice beyond the accepted quota. These are collector probes, not a public API.

This candidate avoids the reproduced `decompress` fragmentation failures. It is
not yet approved for production. Source review of `inflate_reads` and the zlib
stubs shows explicit native cleanup on normal completion and codec errors, but
no public close operation for an abandoned reader. An input callback exception
or an output-budget rejection can leave cleanup to the GC finalizer. The reported
OCaml allocation count excludes zlib's native allocations. A production adapter
needs deterministic cancellation/close semantics, native-memory accounting,
per-call work limits and a supported system-zlib policy. Do not drain hostile
input merely to force cleanup.

Next: investigate an upstream-compatible closeable decoder API (or a backend
with explicit disposal), then test runtime cancellation and retained native
memory. HTTP/2 decoded-header limits and the other Phase 0 gates remain open.

References: [Bytesrw 0.4.0 opam metadata](https://opam.ocaml.org/packages/bytesrw/bytesrw.0.4.0/)
and [upstream source](https://github.com/dbuenzli/bytesrw).

## Explicit-close ownership experiment

The private `test/protocol_foundations/closeable_zlib` library derives the
inflate-reader portion of the pinned Bytesrw release, preserving its ISC
license. It returns a reader and an idempotent close callback and calls the
upstream free operation directly. No new C or codec implementation is added.
It depends on a private upstream C ABI and is not installed or approved for
production; the normal Bytesrw dependency remains unchanged.

Close does not drain input. Source exceptions close the decoder and preserve
their exception/backtrace. Overlapping reads are rejected. A callback resuming
after close is checked before its returned bytes can reach freed native state.
The full gzip controls run against both upstream and this experiment. Additional
checks retain 2,000 closed readers across GC, exercise repeated close and source
exceptions, and verify Eio cancellation during input suspension and Lwt
cancellation after a decoded chunk. These prove lifecycle behavior, not native
allocation accounting. A supported close API, instrumented native-memory checks,
additional cancellation boundaries and system-zlib review remain release gates.
