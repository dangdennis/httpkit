# Application and client dependency experiments

The [Caddy-first roadmap](protocol-libraries-plan.md) owns the active scope.
Private TLS and gzip probes remain relevant to outbound HTTPS, body decoding and
WebSocket compression. They expose no new production packages. Public ingress,
response compression and public assets are delegated to Caddy.

## Run and interpret

```sh
tools/dev protocol-spikes
tools/dune-pkg runtest test/protocol_foundations --force
```

The runner executes native and ordinary bytecode probes and records platform,
source hash and results in `_artifacts/protocol-foundations/report.json`.
`EXPERIMENTS_COMPLETE` means assertions passed; `production_gate: NOT_READY` means
adoption still needs the work below. Allocation diagnostics are not performance
acceptance. AFL remains skipped. Historical reports do not validate changed sources.

## Outbound TLS candidate

The development harness pins `tls` 2.1.2. The probe uses a scoped test trust anchor,
fixed validation time and HTTP/1.1 ALPN. It tests fragmented handshakes, encrypted
data, clean close, wrong-host and unknown-CA rejection. The test server is an
independent peer fixture role, not a planned public TLS server API.

Upstream owns crypto, randomness, certificates and records. Remaining gates:
expiry/malformed chains, negotiation mismatch, handshake work/byte/time limits,
runtime cancellation, trust-store policy, native memory and independent peers.
See [ocaml-tls](https://github.com/mirleft/ocaml-tls).

## Body-codec candidates

The development harness pins `decompress` 1.6.0 and `bytesrw` 0.4.0 with `conf-zlib`.
Only Bytesrw's zlib binding is used; optional crypto bindings are disabled in the
locks. Native zlib version is reported at runtime and is not pinned by opam.
The locked source archive checksums make OCaml source selection reproducible.

`decompress` passes larger fragment/checksum/output-budget controls, but the
one-byte gzip header transition fails on the fixture. An isolated repair did
not resolve optional-header failures; no production patch was adopted.

Bytesrw/native zlib passes the tested one-byte boundaries, filename/comment/extra
headers, concatenated members, corrupt checksums/sizes, trailing bytes and every
proper prefix of the five fixtures. Input and output budgets are tested, including
long optional headers. Limits apply before the collector retains bytes, while a
bounded decoder output slice can exceed the collector's remaining quota.

The stock reader has no public close for early abort. The private `closeable_zlib`
experiment derives the pinned upstream inflate-reader code under its ISC license
and calls upstream native free directly. Close is idempotent, never drains input,
and checks terminal state after source callbacks resume. Tests include source
exceptions, overlapping reads, retained closed handles and Eio input/Lwt consumer
cancellation. It depends on a private upstream C ABI and is not a production API.

Remaining gates: a supported close API or separately reviewed ownership layer,
instrumented native allocations, additional cancellation schedules, bounded work
per event-loop step, native-library maintenance/advisory policy and independently
verified interoperability. No reported OCaml allocation count includes zlib's
native allocations. The previous macOS/Linux observations are historical until
regenerated for current sources.

References: [decompress](https://github.com/mirage/decompress),
[Bytesrw](https://github.com/dbuenzli/bytesrw).

## Next boundary

Build Caddy integration and trusted-proxy acceptance first. Continue TLS/codec
experiments only to support the outbound client, body and realtime phases in the
roadmap. Do not delay application work on retired transport expansion experiments.
