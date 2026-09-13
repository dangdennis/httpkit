# Protocol and transport library implementation plan

Status: proposed implementation plan, 2026-09-13. Baseline: `c47c624` on `main`.
No new protocol support is implemented by this document. Estimates below are
engineering effort, not delivery promises or evidence of security.

## Outcome and constraints

Deliver independently usable HTTP semantics, compression, TLS integration,
clients, HTTP/2, WebSocket additions and eventually HTTP/3. “Fast” means both
shorter implementation time through reuse and measured runtime efficiency.

- Keep pure policy and protocol logic independent of Eio and Lwt. Runtime adapters
  own sockets, clocks, cancellation, worker admission and resource cleanup.
- Do not implement cryptographic algorithms, TLS, certificate validation or QUIC
  packet protection ourselves. Use existing maintained implementations.
- Reuse compression codecs and initially prefer an existing HTTP/2 engine.
  Write the bounded HTTP policy and integration that make them fit our contracts.
- Keep the current HTTP/1 engine working; do not replace it with a universal
  engine before another protocol demonstrates the required abstraction.
- Use OCaml development tools and small shell launchers. AFL remains skipped.
  Keep deterministic generators, corpus replay, shrinking and fault controls.
- Keep README concise; detailed contracts, examples and evidence belong in docs
  and per-library artifacts. No deployment or publication is part of this plan.

## Current boundaries that constrain the design

`Httpkit_core.Version` represents HTTP/1.0 and HTTP/1.1, and request construction
currently defaults to HTTP/1.1. `Httpkit_engine` explicitly admits one exchange at
a time. Consequently, HTTP/2 cannot be implemented by changing a version flag.

The existing transports already supply low-level HTTP/1 client/server operations.
Application packages supply routing, middleware, bodies, sessions, SSE and a
server WebSocket profile. Eio static files currently collect bounded content for
ETags; ranges, compression and Last-Modified are absent. Lwt lacks filesystem
helper parity. OIDC takes a caller-supplied HTTPS client. These APIs remain usable
throughout the work; new integrations must not silently change their defaults.

## Package map

Names below are proposed opam and Dune public library names, not installed or
published packages. Implementation directories may use underscores. Modules use
`Httpkit_` plus the same suffix with underscores.

| Package | Entry module | Ownership and dependency boundary |
| --- | --- | --- |
| `httpkit-headers` | `Httpkit_headers` | Own pure typed HTTP date, validator, range and negotiation helpers; depends on core and a date library if justified |
| `httpkit-compress` | `Httpkit_compress` | Own bounded incremental compression interface and HTTP encoding policy; wrap a selected codec |
| `httpkit-files-eio` | `Httpkit_files_eio` | Own confined streaming file serving; compose headers, Eio and the application API |
| `httpkit-files-lwt` | `Httpkit_files_lwt` | Same file contract using native Lwt cancellation and I/O |
| `httpkit-tls` | `Httpkit_tls` | Shared validated TLS policy and ALPN selection; wrap upstream TLS types/validation |
| `httpkit-tls-eio` | `Httpkit_tls_eio` | Eio handshake and transport adapter using upstream TLS |
| `httpkit-tls-lwt` | `Httpkit_tls_lwt` | Lwt handshake and transport adapter using upstream TLS |
| `httpkit-client` | `Httpkit_client` | Own pure origin, redirect, retry and pool admission policy; no connections or scheduler |
| `httpkit-client-eio` | `Httpkit_client_eio` | Eio connection establishment, bounded pooling, scoped response bodies and protocol backends |
| `httpkit-client-lwt` | `Httpkit_client_lwt` | Equivalent client with native Lwt promises |
| `httpkit-http2` | `Httpkit_http2` | Runtime-neutral HTTP/2 backend facade and bounded integration; initially wrap `h2`/HPACK |
| `httpkit-http2-eio` | `Httpkit_http2_eio` | Eio stream admission, reader/writer ownership and application/client integration |
| `httpkit-http2-lwt` | `Httpkit_http2_lwt` | Equivalent HTTP/2 integration with Lwt cancellation |
| `httpkit-ws` | `Httpkit_ws` | Own extracted client/server WebSocket codec and handshake policy; no runtime |
| `httpkit-ws-deflate` | `Httpkit_ws_deflate` | Optional per-message DEFLATE policy/state over a reused codec |
| `httpkit-http3` | `Httpkit_http3` | Wrap an upstream QUIC + HTTP/3 stack; own safe OCaml bindings and HTTP mapping |
| `httpkit-http3-eio` | `Httpkit_http3_eio` | Eio UDP/timer/stream integration |
| `httpkit-http3-lwt` | `Httpkit_http3_lwt` | Lwt UDP/timer/stream integration |

Keep backend bindings private initially; publish a separate backend package only
if an independent consumer needs it. In particular, do not invent a QUIC library
merely to complete this table. The shared TLS/client packages must earn their
existence with meaningful pure contracts, not empty forwarding modules.
`Httpkit_core.Headers` remains the checked generic header container;
`Httpkit_headers` adds typed field syntax and decisions on top of it.

Once these packages are published, selection would look like:

```sh
opam install httpkit-client-eio httpkit-http2-eio
```

```lisp
(libraries httpkit-client-eio httpkit-http2-eio)
```

```ocaml
module Client = Httpkit_client_eio
module Http2 = Httpkit_http2_eio
```

These demonstrate naming only. Final functions and dependency closures are Phase
0 deliverables; no speculative API call here should be mistaken for usable code.

No dependency cycles: headers/compression/WS depend downward on core, while new
file packages depend on the application packages. Keep existing `Files` working;
deprecate or delegate only when a cycle-free migration is available. Extract
WebSocket code into `httpkit-ws`, then let `Httpkit.Websocket` retain a compatible
alias. Runtime protocol packages adapt handlers supplied by the applications;
application packages need not depend on every optional protocol.

## Phase 0 — prove dependencies and settle the cross-protocol seam

Budget: 1–2 engineer-weeks. This is the first implementation milestone.

1. Capture baseline build/docs, installed consumers, current allocations,
   throughput and retained-memory results with one source hash. Record any
   existing validation gaps separately from new failures.
2. Build small independent spikes for TLS, compression and `h2` against OCaml
   5.5.0 and both Dune locks. Test macOS and Linux, native and ordinary bytecode.
3. For every dependency record license, release/revision, maintenance activity,
   advisories, transitive/native dependencies, build reproducibility, streaming
   API, ownership, resource controls and cancellation behavior. Pin only versions
   actually exercised. Upstream existence is not proof of suitability.
4. Define a narrow protocol backend interface: request metadata, scoped body
   input/output, trailers, completion, cancellation and connection shutdown.
   Keep protocol stream identifiers private and connection-owned. No promise
   abstraction shared between Eio and Lwt.
5. Prototype metadata conversion. Preserve methods, authority, scheme, path,
   repeated headers and trailers. Add an additive protocol-neutral metadata view
   rather than pretending HTTP/2 messages are HTTP/1.1. Document a version-type
   migration if needed; adding constructors can break exhaustive matches.
6. Establish a threat model and resource accounting model before API freeze:
   hostile peers, slow readers/writers, malformed compressed headers/bodies,
   malicious redirects, cancellation races and native-resource misuse.

Deliverables: dependency decision records, runnable spikes, proposed `.mli`
interfaces, compatibility notes and benchmark fixtures. Reject a backend that
cannot bound memory before allocation; post-hoc limits are insufficient. If `h2`
fails this gate, assess upstream fixes first. A new HTTP/2 implementation is a
separate, explicitly re-estimated option, not an automatic fallback.

## Phase 1 — headers and representation policy

Packages: `httpkit-headers`. Budget: 1–2 engineer-weeks.

Own bounded parsing/printing for entity tags, HTTP dates, byte ranges and weighted
content negotiation. Separate parsing from decisions. Return typed outcomes such
as proceed, not-modified, precondition-failed, full representation or partial
representation; applications choose the response construction.

Implement validators and precondition ordering together, then single byte ranges
and If-Range. Preserve weak/strong comparison rules. Define malformed and
unsupported-range handling explicitly; multiple ranges are outside the first
serving profile. Keep syntax acceptance distinct from local resource limits.
Implement Accept-Encoding first; add Accept/media-type negotiation as a separate
slice. Cache directives can be represented without building a shared cache.
[HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110.html) is the conformance reference.

Security controls: checked integer arithmetic, bounded tokens/items/bytes, no
locale-dependent parsing, no stringly typed injection points, and no unbounded
sorting or expansion. Test empty/suffix/unsatisfiable ranges, overflow, duplicate
fields, date boundaries, wildcard/q=0 cases and contradictory preconditions.

Performance: scan once where possible; allocations scale with bounded input,
not numeric range length. Benchmark valid and hostile fields at geometric sizes.
Exit: table-driven normative vectors, generated round trips and decision tests,
negative controls and an installed consumer without Eio/Lwt dependencies.

## Phase 2 — compression and file serving

Packages: `httpkit-compress`, `httpkit-files-eio`, `httpkit-files-lwt`.
Budget: 3–5 engineer-weeks including both runtimes.

Compression codec spike: compare [decompress](https://github.com/mirage/decompress)
with [Bytesrw](https://erratique.ch/software/bytesrw/index.html) and its native
filters. Choose by bounded incremental operation, build footprint and measurements;
do not select a synchronous abstraction that requires blocking Lwt. Start with
identity/gzip; add Brotli/Zstd only after the initial profile is stable and their
native/dependency costs are justified.

We own feed/drain/finish/abort and explicit output credits. No helper may eagerly
inflate a body and only then check its length. Bound compressed input, decoded
output, pending buffers, codec window and processing work. A ratio limit is an
additional signal, never the only decompression-bomb defense. Reject truncation,
checksum errors and unsupported coding chains; specify concatenated-member policy.
Make request decompression opt-in and enforce decoded limits before application
parsing. Treat transparent client decoding as a documented representation change.

HTTP middleware owns negotiation and representation metadata. Merge `Vary`
correctly, remove invalid content lengths and avoid reusing a strong ETag across
different encoded bytes. Default dynamic compression off for secret-bearing
responses mixed with attacker-controlled input. No automatic compression of SSE.

File packages compose the representation decisions with confined filesystem I/O.
Stream large files with bounded chunks; implement HEAD without body production,
Last-Modified, validators and single-range responses. Require descriptor-relative
confinement or an equivalently proven capability strategy, and test replacement,
symlink and rename races. A file descriptor does not make contents immutable:
strong content ETags require immutable/versioned files or a bounded snapshot.
Mutable streamed files use an explicitly documented weaker strategy and abort
on inconsistent reads. No unbounded hash-then-reopen workflow.

Initially range requests use identity representations when acceptable; define a
full-response fallback otherwise. Avoid on-the-fly compressed byte ranges. Keep
upload cleanup behavior, and add equivalent Lwt helpers without importing Eio.

Exit: independent codec interoperability; compressed-bomb and fragmented-input
controls; file mutation/traversal tests; cancellation during read/write/codec
operations; memory independent of total streamed body size; both runtime consumers.
Benchmark compressible/incompressible payloads, tiny chunks, large files and slow
readers. Native codec CPU work must not monopolize an event loop: cap work per
step or use bounded workers if the backend cannot yield within that budget.

## Phase 3 — HTTPS integration

Packages: `httpkit-tls`, `httpkit-tls-eio`, `httpkit-tls-lwt`.
Budget: 2–3 engineer-weeks.

First candidate: [ocaml-tls](https://github.com/mirleft/ocaml-tls), whose core is
I/O-independent and has Eio/Lwt integrations. We wrap configuration, identity,
ALPN, handshake lifetime and transport ownership. Upstream owns TLS records,
cryptography, randomness and certificate verification. Confirm cancellation and
partial-I/O behavior experimentally rather than wrapping incompatible channels.

Client defaults require chain and hostname/IP verification with explicit trust
configuration. Keep peer address, SNI and expected identity distinct. No ambient
“disable verification” environment switch. Test CAs are scoped test fixtures.
Delegate certificate time checks and supported algorithm policy upstream; record
trust-store and certificate revocation limitations rather than promising more.

Bound concurrent handshakes, handshake bytes/time, buffers and shutdown time.
Distinguish clean TLS closure from truncation. Verify server/client ALPN results
before selecting a protocol; never downgrade from failed HTTPS to cleartext.
Use current upstream secure protocol defaults with a documented minimum version.
Keep early data disabled initially. Certificate reload is atomic for new
connections and does not invalidate ownership of active sessions.

Exit: local CA tests for trusted/untrusted, expired, wrong-host and malformed
certificates, ALPN mismatch, fragmented handshakes, EOF and cancellation. Run
independent TLS client/server interoperability. Benchmark handshake latency,
concurrent-handshake pressure, reuse and steady-state encrypted throughput.

## Phase 4 — usable HTTP clients

Packages: `httpkit-client`, `httpkit-client-eio`, `httpkit-client-lwt`.
Budget: 3–5 engineer-weeks for HTTP/1 plus the backend seam.

Pure policy owns normalized origin keys, redirect decisions, retry eligibility
and admission accounting. Runtime packages own resolver/connect/TLS operations,
connection pools and structured lifetime. Reuse a maintained URI parser; do not
write DNS wire handling. Add HTTP/2/3 backends later without forcing them into the
HTTP/1 engine. Supply a bounded HTTPS client to the existing OIDC adapter.

Expose a scoped streaming request API. A response body cannot silently escape
its connection lease. Complete, bounded-drain or close determines reuse; aborted
HTTP/1 bodies cannot put a poisoned connection back into the pool. Collecting a
body is a separate helper with a mandatory finite cap.

Defaults: bounded total/per-origin connections and waiters, finite idle expiry,
monotonic end-to-end deadline, no automatic retries, no redirects unless enabled,
no cookie jar, no ambient proxy configuration, no cross-origin connection
coalescing. Body replayability is explicit; idempotent method alone does not
prove that a consumed body can be resent. Use bounded attempts/backoff only when
caller policy enables retries. Honor retry hints within the same deadline.

For enabled redirects, enforce a hop cap, clear cross-origin credentials, rebuild
Host/authority and forbid HTTPS downgrade by default. SSRF-sensitive consumers
supply an egress policy checked for every redirect and every resolved address;
connect only to a vetted address and bind TLS identity to the requested host.
Do not globally ban private addresses for legitimate internal-service clients.

Exit: pool exhaustion, lease leak, cancellation at each stage, stale connections,
partial writes, redirect loops, credential leakage, DNS/address-policy races and
retry duplication tests. Compare connection reuse and allocation with direct
transport calls. OIDC tests must show limits enforced while reading, not after
an oversized provider response has already been allocated.

## Phase 5 — HTTP/2

Packages: `httpkit-http2`, `httpkit-http2-eio`, `httpkit-http2-lwt`.
Budget: 4–7 engineer-weeks if the selected upstream passes Phase 0.

Evaluate [ocaml-h2](https://github.com/anmonteiro/ocaml-h2) first. It includes HPACK
and runtime integrations. Prefer adapting its core to our ownership contract;
reuse upstream runtime adapters only when their semantics satisfy our limits.
Do not duplicate HPACK or frame parsing around the same backend. Record supported
features against [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html), not merely
an older conformance tool's pass count.

Our wrapper owns checked metadata conversion, explicit stream handles, admission,
backpressure, error mapping and scoped body lifetime. Connection failure and
stream failure are different outcomes. ALPN dispatch selects a separate HTTP/2
engine. Start with HTTPS; explicit prior-knowledge cleartext may be a test/internal
option. No implicit protocol guessing, server push or cross-origin coalescing.

Validate pseudo-header order/uniqueness and required values, authority consistency,
forbidden connection-specific fields, body lengths and trailer restrictions.
Bound decoded header bytes/count and HPACK state before allocation. Bound streams,
queued output, aggregate body retention, frame/control processing and scheduling
work; DATA flow-control windows alone do not bound headers or control frames.
Protect against rapid creation/reset cycles, SETTINGS/PING floods and pathological
CONTINUATION sequences. Use the current normative spec and adversarial traces.

Replenish receive credit as the application consumes or safely discards data.
A slow stream must not retain unlimited memory or starve ready streams. Separate
stream timeout/reset from connection timeout/shutdown. GOAWAY drains eligible
streams and communicates retry eligibility without resending implicitly.

Exit: reference client/server tests, fragmentation at every boundary, stateful
sequence generation, flow-control deadlock tests, stream cancellation races and
fairness under mixed large/small responses. Verify native/bytecode consumers and
both application/client integrations. Measure latency distributions, throughput,
allocations and RSS across stream concurrency, slow consumers and reset floods.

## Phase 6 — WebSocket completeness

Packages: `httpkit-ws`, optional `httpkit-ws-deflate`; integrate with existing Eio
and Lwt realtime APIs. Budget: 2–4 engineer-weeks.

Extract existing server code without behavior changes and retain its old module
alias. Add client-role framing/masking, handshake verification and deterministic
subprotocol selection. Use upstream secure randomness for masks. Keep explicit
Origin policy for browser servers. Bind selected subprotocols to the offered
set; reject conflicting/duplicate handshake fields. Do not imply WebSocket-over-
HTTP/2 or HTTP/3 merely because the underlying HTTP protocol is available: extended
CONNECT is a separate later integration with its own acceptance tests.

Compression remains a separate opt-in dependency. Reuse the chosen DEFLATE codec;
implement [RFC 7692](https://www.rfc-editor.org/rfc/rfc7692.html) negotiation and
message state. Start with an explicit no-context-takeover profile. Apply limits
after inflation, preserve fragmentation/control-frame behavior and retain the
policy against compressing secrets with attacker-controlled data.

Exit: role/masking violations, UTF-8 split boundaries, oversized messages,
fragment/control interleavings, handshake/subprotocol mismatches and close races.
Replay an independent interoperability corpus with an OCaml runner; do not add a
Python tool dependency. Benchmark tiny messages, large fragmented messages,
compression and slow consumers. Never retain an unbounded complete message.

## Phase 7 — HTTP/3, staged separately

Packages: `httpkit-http3`, `httpkit-http3-eio`, `httpkit-http3-lwt`.
Budget: 2–3 engineer-weeks for a binding spike, then 6–10 for integration if viable.

Start only after the stream/lifetime model has proved useful in HTTP/2. Evaluate
[quiche](https://github.com/cloudflare/quiche) as a QUIC + HTTP/3 backend, including
its supported C ABI, licensing, native toolchain and TLS backend. Compare other
maintained backends if portability or ownership cannot be satisfied. Do not claim
an existing OCaml binding has been found or is compatible until the spike proves it.

Upstream owns QUIC recovery/congestion, packet protection, transport parameters,
QPACK and HTTP/3 protocol state. Our work is binding safety, bounded UDP/timer
integration, HTTP metadata and scoped streams. HTTP/3 uses QPACK rather than
HPACK; see [RFC 9114](https://www.rfc-editor.org/rfc/rfc9114.html).

Audit every FFI lifetime: roots, copying/pinning, callbacks, exceptions, native
handles, explicit close, domain affinity and finalizer fallback. Native memory
must be counted with OCaml heap memory. Test ordinary bytecode dynamic loading.
Reject a backend whose native queues cannot be bounded by configuration/admission.

Initially disable 0-RTT, active migration, datagrams, WebTransport and extended
CONNECT. Model loss, reorder, duplicate datagrams, handshake timeout, address
validation and stream shutdown. Bound connections, streams, datagrams, timers,
QPACK tables/blocked streams and amplification before address validation. Leave
anti-amplification and cryptographic enforcement upstream and test their integration.

Exit: independent HTTP/3 peers under a reproducible network impairment harness,
FFI sanitizer runs, packet/timer replay, cancellation, shutdown and long memory
plateaus. Benchmark against upstream directly to isolate wrapper cost. Shipping
HTTP/1 and HTTP/2 must not wait for this phase if its backend gate fails.

## Common security, performance and review gates

Every library follows the same small delivery cycle:

1. Write the contract, limits, ownership and error taxonomy before implementation.
2. Deliver one complete positive path plus adversarial tests and an installed
   example. Avoid scaffolding many empty packages at once.
3. Review parsing, arithmetic, state transitions and resource cleanup; then review
   cancellation/race paths and dependencies. Refactor before adding features.
4. Run generated cases, fixed regression corpora, shrink/replay and targeted
   compiled fault mutations. Use an independent implementation where available.
5. Measure and review; optimize the demonstrated bottleneck without weakening
   bounds. Re-run only the affected gates during iteration, then the full matrix.

Initial configurable budgets to validate in spikes: 64 KiB application chunks,
64 KiB decoded header sections, 100 fields, 100 admitted HTTP/2/3 streams per
connection, 1 MiB aggregate queued application output, and finite global admission
and wait queues. These are proposed policies, not protocol maxima or a total-RSS
guarantee. Backend buffers, TLS/codec windows, native allocations and active
handlers need separate bounds. Derive an aggregate memory budget before accepting
those defaults; protocols may require a different internal frame/window size.

Hard properties: no unbounded queue/allocation on peer-controlled lengths; bounded
per-step processing; no descriptor/task/lease leaks; cancellation joins owned work;
no duplicate application operation from implicit retries; no credentials in logs.
Core remains independent of runtimes, TLS and test tooling.

Performance reports include workload/source hashes, compiler/dependency versions,
CPU/OS, repetitions, distributions, allocations and RSS. Exercise geometric sizes,
concurrency, fragmented I/O, slow peers, cancellation and hostile inputs. Streaming
memory must plateau as total body size grows. Use stable-runner baselines to set
regression budgets after the spike; do not invent universal requests/second goals.
As an initial review trigger, investigate repeatable >10% throughput/p95 regression
or >10% allocation growth against the same workload, including variance and causes.
Do not turn noisy measurements into automatic correctness failures.

Release evidence per phase: build/docs; native and ordinary bytecode isolated
consumers; Eio without Lwt and vice versa; macOS/Linux; relevant real peer tests;
positive and negative controls; line/point coverage with an uncovered-branch review;
mutation results; resource/performance results; 30-minute adverse-load canary and
two-hour soak for new runtime paths. Coverage is a test-gap signal, not a security
score. Preserve all failures, source hashes and exact commands. AFL stays recorded
as skipped; no fuzzing claim may imply otherwise. Hosted CI and independent
security review are separate gates, and must not be marked passed when unavailable.

## Delivery sequence, effort and stop conditions

| Order | Deliverable | Engineer-weeks | Required predecessor |
| --- | --- | --- | --- |
| 0 | Dependency spikes, threat model and metadata seam | 1–2 | Current baseline |
| 1 | Headers and representation policy | 1–2 | Phase 0 contracts |
| 2 | Compression and files on both runtimes | 3–5 | Headers, codec selection |
| 3 | TLS on both runtimes | 2–3 | TLS spike |
| 4 | HTTP/1 client facade and OIDC integration | 3–5 | TLS and backend seam |
| 5 | HTTP/2 client/server integration | 4–7 | HTTP/2 spike, TLS, seam |
| 6 | WebSocket client/subprotocols/compression | 2–4 | Extraction and codec selection |
| 7 | HTTP/3 spike and integration | 8–13 | Stream model and backend gate |

Phases 0–6 total roughly 16–28 engineer-weeks for one engineer; HTTP/3 brings the
whole scope to roughly 24–41. These include focused implementation, tests and docs;
allow additional capacity for upstream changes, failed experiments, independent
review, stable performance infrastructure and release findings. Some phases are
independent, but concurrency is a staffing decision, not assumed in this estimate.
A from-scratch HTTP/2 implementation would invalidate the Phase 5 estimate.

Stop or narrow a phase when bounds require unsafe assumptions, a dependency lacks
required controls, OCaml 5.5/native/bytecode cannot be supported, or measured wrapper
cost cannot be explained. Record the result and a concrete alternative. Do not
replace external crypto with local implementations to work around incompatibility.

The first actionable slice is Phase 0: a dependency compatibility report and
three bounded echo/streaming spikes. Then ship headers, one codec and one file
path before expanding the runtime matrix. This document does not implement these
libraries or schedule execution.
