# Production-confidence roadmap

Updated 2026-09-14 after the [repository audit](production-audit.md), baseline
`88c8ed5`. This supersedes the feature-expansion and Caddy-first delivery plans.
Strict HTTP/1.1 is the production protocol target. Implementation is substantial;
production confidence, evidence and API stability are the work now.

## Direction and responsibility

Canonical: Internet -> HTTPS Railway edge -> httpkit listening on `$PORT`.
Optional: Internet -> HTTPS Railway edge -> Caddy -> Railway private network or
localhost -> httpkit. Caddy must earn its operational cost; it is not required.
See [deployment recipes and trust boundaries](deployment.md).

httpkit owns checked HTTP semantics, parsing/encoding, exchange state, bounded
streaming/backpressure, routing, middleware, application dispatch, cookies,
sessions, forms/multipart, WebSocket protocol, SSE and small safe application
helpers. Infrastructure may provide public TLS, certificates, advanced public
protocols, proxying/routing, compression, asset delivery and security services.
Do not assume a WAF or DDoS product exists just because an edge is present.

Keep core -> codec -> Sans-I/O engine -> native runtime transport -> application
composition -> optional extensions. New packages require a meaningful dependency
or independently useful contract; no package roadmap exists merely to match other
frameworks. Reuse crypto and security-sensitive dependencies; never implement
cryptographic algorithms. Keep working code unless evidence warrants a change.

## Execution rules and status

Each item below is a local issue-sized backlog entry, not a published GitHub issue.
Owner for implementation/triage: repository maintainer; independent reviewers must
be named separately when those gates run. Status is open unless explicitly stated.

For each slice: state invariant, identify/add a failing control or coverage gap,
make the smallest change, run narrow tests then relevant regressions, inspect
security/performance effects, update semantics/docs and retain source-matched
results. No giant rewrite, speculative optimization or implicit API churn.
Use reviewable commits. AFL remains skipped; deepen generated/replay/fuzz work in
OCaml. Skipping AFL must remain visible and must not be relabeled campaign success.

## Autonomous incremental delivery

Continue one invariant-sized slice at a time without routine supervision.
CI work is explicitly deferred by user instruction: do not inspect, modify or
wait on hosted CI; use local tests and keep hosted evidence unclaimed. After
focused tests, relevant regressions and a code-quality/security review, commit the
completed slice and push `main`. Record evidence and remaining gaps here. A failing
or unavailable external gate stays open while independent local work continues.
Do not deploy services or invent independent approval to satisfy a release gate.

| Order | Slices, executed separately | Exit invariant |
| --- | --- | --- |
| 1 | CL/TE policy matrix; chunk/trailer matrix; EOF/special responses | Explicit expected outcomes independent of parser behavior, segmentation parity |
| 2 | Pipelining; unread/discarded bodies; early rejection; partial output | No suffix dispatch after rejection; no cross-exchange data |
| 3 | Parsing/handler/stream cancellation; graceful shutdown | Eio/Lwt release and join every owned resource |
| 4 | Exact/overflow limits; stalled uploads; slow readers; idle connections | Finite retained queues and effective deadlines |
| 5 | Direct proxy contract; trusted metadata; optional Caddy acceptance | Untrusted metadata cannot affect identity/origins |
| 6 | Upload cleanup; DB cancellation; session rotation | No leaked files, leases or locks |
| 7 | Observation contracts; API cleanup; duplicated pure policy | Explicit ownership/errors and native-runtime parity |

Extend OCaml generated/replay campaigns alongside each reviewed subsystem. Capture
real endpoint baselines early, before production changes accumulate; profile before
optimizing. WebSocket security and the remaining P1 campaigns follow P0 dependencies.
P2 remains demand-gated: autonomous execution does not authorize indiscriminate
feature expansion or change the infrastructure exclusions at the end of this plan.

Completed slices (relevant local regression evidence is retained under
`_artifacts/production-slices`):

- Segmentation/EOF/terminal-error controls (`ec5a0f5`); full macOS validation.
- Explicit CL/TE policy plus rejected-head isolation (`0737b76`).
- Chunk/extensions/trailers and cumulative quotas; malformed-body isolation in
  normal and discard modes (`test/engine/chunk_test.ml`).

- Special-response framing and EOF (`test/http1/response_policy_test.ml`),
  including every informational status and encoder/decoder parity.

- Connection reuse across segmentation, normal/discard bodies, partial output
  acknowledgements and early rejection (`test/engine/reuse_test.ml`).

- Existing parser fuzz target now shares real-EOF/progress/terminal-error controls,
  random segmentation and grammar-aware chunk/trailer inputs. `dune runtest` adds
  seeded OCaml smoke for request/response/chunked, without invoking AFL.

- Local existing framework profile captured before runtime changes: three
  10-second epochs at concurrency 1/4/8, source-matched report under
  `_artifacts/framework/profile-3b7261`. This is a local reference, not the final
  five-endpoint benchmark matrix or a stable regression threshold.
- [Lifecycle ownership matrix](lifecycle.md) and suspended callback cleanup:
  Lwt transport teardown now joins handler finalizers before close; regression
  reproduced early teardown before the fix, with matching Eio control.

- URL/forms/router/multipart/WebSocket generated targets are registered in the
  shared fuzz catalog and native seeded smoke; accepted multipart/WebSocket streams
  must agree across segmentation, with explicit event/limit invariants. WebSockets
  remain experimental; this is smoke evidence, not the complete security campaign.

- Multipart limit regression reproduced segmentation-dependent rejection near
  `max_int`; header delimiter allowance now uses overflow-safe arithmetic. Exact,
  one-over, zero and extreme limits run under every segmentation schedule.

- CI no longer schedules the legacy AFL job on pushes. Native generated-input
  smoke remains in correctness validation; missing long-campaign evidence is
  still NOT_READY, and this change does not waive release policy.

- Shared pure proxy policy replaces duplicate Eio/Lwt parsing, preserves the
  X-Forwarded-For default and permits explicit X-Real-IP selection. Pure and native
  application controls cover spoofing/duplicates/chains and profile selection.
  Live deployment trust/topology acceptance remains open.

- Temporary upload callback scope now matches the public ownership contract:
  each file is removed before processing the next part. A two-part regression
  reproduced excessive lifetime; callback errors and partial cancellation remain
  covered. Disk exhaustion and cleanup-I/O fault schedules stay open.

- Lwt request and WebSocket deadlines now join owned work after cancellation.
  Controlled-clock regressions reproduced early closure while finalizers were
  suspended; handler, stream and external-cancellation schedules are covered.
  Nonterminating cleanup and remaining fault interleavings stay explicit limits.

- The local Eio endpoint profiler now measures the five fixed HTTP workloads
  separately at concurrency 1/4/8 with repetitions, warm-up, payload verification,
  CPU/allocation/GC counters, latency upper bounds and cleanup observations.
  Reports retain source/binary/workload identity and build-profile limits. This
  is the first application matrix, not release thresholds or Lwt parity.

- Pure session issuance rejects clock-plus-TTL overflow and loss of positive
  expiry precision. Regression controls prove rejection consumes no entropy or
  capacity and failed rotation restores the previous session.

- End-to-end profiling exposed an inefficient byte-at-a-time load-client read
  path. A bounded 8 KiB buffer preserves response suffixes and EOF, with syscall
  controls and per-operation read counts in reports. Benchmark interpretation
  must distinguish client improvements from server improvements.

- Upload I/O fault controls now inject disk-full writes, close failure and a
  retryable unlink failure against real confined files. Cancelled callback
  cleanup is joined before unlink and connection EOF. Persistent filesystem
  failure and simultaneous-error precedence remain open.

- Database lifecycle controls suspend a cancelled transaction's finalizer while
  closing the pool, then verify rollback from a separate pool. Admission closes
  immediately, shutdown joins cleanup, and interrupted close remains terminal
  but retryable. These controls run against SQLite and disposable PostgreSQL;
  backend I/O and disconnect-failure schedules remain open.

- [Native generated-input campaigns](native-fuzz.md) run the full shared target
  catalog with explicit seed batches, timeouts, source/binary identity and durable
  per-process logs. Failures remain failed reports, including timeout/interruption;
  smoke evidence and longer campaigns are recorded separately. Automatic input
  minimization and release-duration acceptance remain open; AFL stays skipped.

- Both application servers now expose the existing checked transport timeout
  policy. Controlled clocks verify custom header/body/write/keep-alive/graceful
  deadlines and single close through Eio and Lwt. Defaults and the independent
  application request deadline are unchanged; aggregate budgets remain open.

Next: broader local limits and application-resource schedules; release-profile
and Lwt benchmark parity remain open. CI work remains deferred.

## P0 — required before production confidence


| ID | Concrete deliverable | Acceptance / next boundary |
| --- | --- | --- |
| P0-01 | HTTP/1 hostile corpus and segmentation runner | Same semantic outcome under arbitrary segmentation, bounded progress, exact success suffix, terminal error/EOF; first slice implemented in `test/http1/segmentation_test.ml`, campaign remains open |
| P0-02 | Framing/smuggling and encoder/engine review | Explicit strict-policy matrix, malformed input never dispatches a suffix, encoder round trips and connection-reuse controls |
| P0-03 | Lifecycle/resource matrix and cancellation campaign | One owner per resource, deterministic close/join, no surviving FD/task/lease/temp-file/buffer after every injected interruption |
| P0-04 | Deeper non-AFL property/fuzz campaigns | All parser/application targets below, persisted seeds, shrinking and a regression per real finding; release duration/evidence policy reconciled explicitly |
| P0-05 | Slow-client/backpressure stress | RSS/queues plateau; deadline/cancellation releases blocked producers; large idle-connection and small-request concurrency profiles |
| P0-06 | Reproducible end-to-end baselines and allocation profiles | Fixed endpoint/workload matrix, p50/p95/p99, CPU, allocations and GC/RSS; explain copying before optimizing |
| P0-07 | Production limits inventory and safe deployment profile | Actual defaults/units/owners and combined budgets documented; unsafe unlimited modes explicit; exact-limit/overflow tests |
| P0-08 | Trusted-proxy correctness | Default ignores forwarding data; explicitly trusted immediate peer, tested topology recipes, no implicit first/last-address trust |
| P0-09 | Claims, dependencies and release inventory | Every supported feature has evidence/status; vulnerability/maintenance/transitive review; missing gates stay NOT_READY |
| P0-10 | Multipart/upload and auth/DB resource review | Confined exclusive temp paths, cancellation/disk-failure cleanup; bounded DB waits/rollback/session rotation/password work admission |

### P0-01/02 protocol matrix

Cover equal/conflicting/duplicate/comma Content-Length; TE, TE+CL, duplicate TE,
unsupported coding chains; malformed/overflow chunk sizes/extensions/CRLF/trailers;
premature EOF and close framing; absent/invalid body framing; HEAD, all informational
responses, 204/304 and applicable CONNECT/upgrade semantics. Check malformed
request/status lines, methods/targets/versions, whitespace, obs-fold, header names/
values, CR/LF/NUL/control injection and start-line/field/head/count/body limits.
Check signed/overflowing lengths and failure-state reuse.

Exercise whole input, every byte, each single split and deterministic random
multi-splits for heads and bodies, including multiple messages in one read.
Engine controls cover pipelining, cancellation/timeouts during partial parsing,
disconnect mid-body, unread handler bodies, early rejection, explicit discard,
output acknowledgements and reuse. Document deliberate strict policy where peers
accept ambiguous forms. Another parser is never the specification.

Build a systematic corpus: valid RFC-style vectors, malformed cases, published
smuggling patterns with provenance, parser edge cases, slowloris segmentation and
chunk/trailer ambiguities. Expand existing http/af/curl/Nginx lanes with pinned
Caddy and, where practical, llhttp/Node and Hyper. Record disagreements and triage;
expected strict disagreements are not silently normalized away.

### P0-03 lifecycle matrix

For listener, connection, exchange, request reader, handler, response producer,
stream, WebSocket, DB lease/transaction, session state/lock, upload and file handle,
record owner, close authority, idempotence, exception/cancellation/disconnect and
graceful-shutdown behavior, escape rules and concurrent-use policy. Use current
interfaces as evidence; proposed invariants are not already proved guarantees.

Inject SIGTERM idle/during parsing/handler/streaming; disconnect during handler or
blocked output; exceptions before and after headers; body overflow; header/body/
response deadlines; cancelled transactions/uploads/WebSockets. Compare observable
Eio/Lwt semantics while preserving native cancellation models. Assert original
failure precedence, joined work and closed resources, not merely returned status.

### P0-04 fuzz/property scope

Targets: requests, responses, chunking, engine states/sequencing, router raw paths,
URL decoding, forms, multipart, WebSocket frames and message reassembly. Extend the
existing corpus/replay/shrinker rather than making a second runner ecosystem.

Properties: bounded retained memory/queues, valid framing only, encoder/decoder
consistency, reachable engine states, deterministic failure, no cross-exchange
leakage, cancellation retirement, monotonic consumed-prefix progress and bounded
work without input consumption. Preserve original findings before minimization.
Generated smoke and release-length campaigns are different evidence. Reconcile the
current AFL-oriented machine policy through review; do not reduce requirements
just to turn the release report green.

### P0-05/06 stress and performance program

Endpoints: `GET /plaintext`, `GET /json`, `POST /echo`, `GET /small-stream`,
`GET /large-stream`. Reuse existing harness/load metrics. Record payloads,
concurrency, keep-alive, compiler/locks, hardware/OS, source/workload hashes,
warm-up, repetitions and latency distributions. Measure throughput, CPU,
allocations and bytes/request, minor/major GC, RSS, connection scaling and slow/
streaming workloads. Label histogram upper bounds accurately.

Compare equivalent ownership/workloads against Dream, an httpaf server, Hyper/
Axum and Go net/http where feasible. Benchmarks explain cost; winning is not the
gate. Profile socket -> transport buffer -> parser -> values -> router -> middleware
-> handler -> response -> encoder -> transport. Investigate normalization/lookups,
substrings/targets/captures, chunk ownership, buffer/queue nodes, representation
conversions, logging and temporary closures. Require evidence before any optimization.

Stress fast producer/slow client, slow producer/fast client, trickled headers,
stalled/never-completed uploads, unread bodies, disconnected streams, failing
blocked producers, thousands of idle connections and concurrent tiny requests.
Prove finite queues and resource plateaus, deadline enforcement and eventual
producer failure/unblocking. Run 30-minute canaries and two-hour soaks on frozen
sources for new runtime paths; preserve failures and exact budgets.

### P0-07 limits inventory

The [current defaults inventory](production-limits.md) records source owners and
known gaps; it is not yet an aggregate production profile.

Document actual request/status/header-line, aggregate-header/count, body, response
buffer, multipart parts/per-part/total/header, JSON depth/bytes, URL/form, WebSocket
frame/message, active/queued connections, engine queues, read/write/header/body/
exchange/idle/graceful timeouts. Separate logical byte limits from total process
memory (GC, native windows, staging and application retention). Lower-level
unbounded body streaming may remain explicit; application defaults must be finite.

### P0-08 proxy trust

Verify direct Railway, Railway -> Caddy, Cloudflare -> Railway and Cloudflare ->
Railway -> Caddy profiles independently. Audit X-Forwarded-For/Proto/Host and RFC
Forwarded (explicit rejection is valid). The existing single-IP helper is not a
verified chain parser. Establish immediate-peer trust via actual deployment
isolation/identity; a private address or header alone proves nothing. Avoid implicit
chain traversal. Keep external scheme/host separate from socket metadata and
validate application origins/redirects. Deployment recipes must state unverified
assumptions; do not invent Railway trusted CIDRs.

### P0-09/10 feature security and supply chain

Audit necessity, maintenance, security history, transitives, native ABI/runtime
assumptions and sensitive use. Keep core/codec/engine minimal and locks reproducible.
Review cookie replay/rotation/revocation and CSRF semantics, process-local OIDC
flows, HTTPS callback limits, bounded password worker admission, DB cancellation,
rollback, pooled resource escape and cleanup error precedence.

Multipart campaign covers boundary confusion/length/overlap, terminators, part/
header/byte counts, Unicode/NUL filenames, traversal, cancellation/partial uploads
and disk exhaustion. Filename is metadata; exclusive generated paths live only
inside confined directories. Document ownership after callback and cleanup on all
paths. A successful unit test is not upload-security approval.

## P1 — important before API stabilization

| ID | Deliverable | Acceptance |
| --- | --- | --- |
| P1-01 | Runtime-neutral observations | Connection/request/stream lifecycle and counters with privacy-safe defaults; sinks cannot silently break transport ownership |
| P1-02 | Public API usability/error audit | Safe examples, opaque internals, explicit scope/concurrency/results/exceptions/cancellation; break bad pre-1.0 APIs only with evidence |
| P1-03 | Package and pure-policy consolidation | Keep meaningful boundaries; remove ceremony/duplicate pure policy with parity tests; no universal runtime abstraction |
| P1-04 | WebSocket security campaign | Evidence for every rule below or remain explicitly experimental |
| P1-05 | Deployment recipes and real topology acceptance | Railway direct is simplest, optional Caddy recipe, immutable vs persistent storage; trusted-header observations and lifecycle traces |
| P1-06 | Broader interop and stable CI comparisons | Pinned reference matrix and reviewed disagreements; fail only clear repeatable regressions, not laptop noise |
| P1-07 | Small static-file audit | Confined roots/traversal/hidden files, basic MIME, HEAD/ETag/If-None-Match, finite file limits and needed streaming |

Observation events: accept/close, request start/finish/status/duration, measurable
TTFB, bytes read/written, active connections, queue depth, admission/body-limit
rejection, timeout/disconnect/handler or stream failure, WebSocket open/close and
shutdown progress. Define handler duration versus response completion explicitly.
Allow OpenTelemetry, Prometheus, structured logs, StatsD and custom sinks via
adapters. Default events exclude authorization, cookies, bodies and sensitive query
values; do not hard-wire a vendor or unbounded asynchronous event queue.

WebSocket review: masking, fragmentation/continuations, control frames, valid close
codes, UTF-8 across fragments, ping/pong, frame/message limits, timeouts, concurrent
sends, cancellation/partial writes/disconnects, upgrade validation and extension/
subprotocol rejection or negotiation. Keep it experimental until independent
feature-specific evidence supports a stronger claim. No feature expansion is needed
to label current support honestly.

Static serving stays small. Measure existing bounded collection/HEAD costs before
changing to streaming. Advanced ranges, precompressed negotiation, large-file
optimizations, autoindex and cache-server behavior need concrete application demand.

## P2 — useful later, only with demonstrated demand

Typed application validators/negotiation, an outbound client convenience layer,
additional runtime-specific filesystem/DB parity, WebSocket client/subprotocols,
and opt-in body/message compression may be useful. Reuse existing APIs/upstream
libraries first. Their previous package names and delivery estimates are no longer
commitments. Do not let TLS/codec research gate core correctness or deployment.

No automatic universal observability adapter suite, broad framework feature parity,
or speculative zero-copy redesign. Promote a P2 item only with a consumer, contract,
security/resource budget and evidence that it improves the application abstraction.

## Won't build / delegated to infrastructure

ACME, certificate lifecycle and production TLS termination; new public transport
stacks; QUIC; reverse proxy server, load balancer or backend health-checking system;
CDN/sophisticated edge cache; general-purpose compression-server infrastructure;
nginx/Caddy-style virtual-host configuration; WAF/DDoS/global edge rate limiting.
HTTP/2 is not a priority and HTTP/3 is excluded. No related implementation work is
reintroduced. Infrastructure support does not waive backend HTTP/1 validation.

Application readiness endpoints and locally bounded application admission are
legitimate app lifecycle features; they are not a backend health-check service or
an edge traffic-management product. TLS for outbound HTTPS may use upstream code
when a concrete client need is approved; it is not public TLS termination.

## Release checklist

- Formatting; locked compiler/platform build matrix; unit/property/conformance tests.
- Fuzz smoke and reviewed longer campaigns, explicitly recording skipped AFL.
- Eio/Lwt, cancellation, resource-leak, slow-client/backpressure and shutdown tests.
- WebSocket/multipart/DB/auth/session feature evidence with experimental exclusions.
- Real interop/proxy lanes, source-matched benchmark baseline and regression review.
- Dependency vulnerability/maintenance/license review and native resource accounting.
- Isolated native/ordinary-bytecode installation, runtime dependency isolation,
  examples built/run, documentation and deployment recipes validated.
- Coverage-gap and mutation review, canary/soak results, independent security/API
  review, verified private vulnerability-reporting channel and hosted CI evidence.

Missing, stale or failed evidence means NOT_READY. The machine gate inventory must
be expanded to match supported features; a human checklist alone does not do that.
Do not fabricate approval records or treat a successful push as release approval.
