# Benchmark experiments and remaining work

Owner: the http-kit repository. Updated 2026-09-11. This is the persistent
benchmark backlog; checked items mean implemented and exercised, not a production
performance or security approval. Commands and comparison boundaries live in
[benchmarks.md](benchmarks.md). Release campaigns remain governed by the
[M7 checklist](m7-manual-checklist.md).

## Existing coverage

- [x] Five-family primitive suite: core, router, HTTP/1 codec, middleware and engine.
- [x] Pinned Routes/httpaf/httpun comparison dependencies in both Dune locks.
- [x] External route construction, scaling and capture shapes; raw request/response head parsing.
- [x] Repeated release samples, source/workload provenance, allocation/GC metrics, noise reporting and compatible baseline checks.
- [x] Existing Eio/Lwt loopback mixed workloads and streaming queue-bound smoke.

## Current experiments

- [x] Body comparisons through public connection APIs: incoming requests and responses, fixed/chunked/close-delimited framing, empty/tiny/large/binary payloads, many wire chunk sizes and transport fragments.
- [x] Owned-body comparison: copy external borrowed buffers before retaining/checking data so ownership requirements match our owned Data events.
- [x] Deterministic irregular fragmentation and deferred body consumption; complete-body/EOF and exact-byte oracles.
- [x] Router candidate index prototype in benchmark code, preserving declaration order and delegating matching/policy to the existing router.
- [x] Differential checks against the reference matcher, including overlaps, methods/Allow, raw targets, root/wildcards and limits.
- [x] Measure index construction, candidate duplication, lookup scaling, shared prefixes and fallback-heavy tables before considering production adoption.
- [x] Retain full measurements, interpret limitations, and make the CI smoke cover the new matrices.

The body matrix now has 390 timed cases plus the original 16 excluded workload
groups. There are 108 writer/exchange cases and 252 three-implementation router
experiment cases. Both indexes run 12,024 differential queries each. Four
kit-only engine cases cover Expect and early final responses. These are local
experiments, not release readiness.

## Follow-up execution (the five proposed priorities plus persisted findings)

- [x] Profile the 64 KiB/17-byte-chunk case with payload/read counters, separate OS stack samples and allocation/heap/RSS diagnostics.
- [x] Add public response writers, complete server exchanges, eight-message pipelines, partial acknowledgements and exact output oracles.
- [x] Add upstream borrowed scans alongside owned scans/collection; document that kit Data stays owned.
- [x] Refine the index to store each route once under a deep literal prefix; add application-shaped mixed-method and hot-route workloads.
- [x] Add calibrated batch duration, independent-process median intervals, short/noisy case labels and load observations. A reserved host and reviewed budgets remain outstanding.
- [x] Persist commands, interpretation and remaining gaps in this plan and [the results document](benchmark-results-2026-09-11.md).

## P0: make the comparisons more representative

- [x] Add response-body serialization through public writer APIs: fixed/chunked, finalization, empty writes, partial output acknowledgements and stable-buffer lifetime.
- [ ] Extend the writer comparison to outgoing client uploads and zero-copy scheduled buffers.
- [x] Compare complete server request/response exchanges with outgoing bytes drained, persistent reuse and bounded pipeline input.
- [x] Measure kit-only 100 Continue and early-final upload policy cases.
- [ ] Align cross-library Expect/early-final policies and drive complete client/server pairs.
- [ ] Separate body setup/head cost from steady-state transfer cost, and sweep body-buffer sizes on each public API.
- [x] Add borrowed-buffer scan and owned collection lanes; separate post-cleanup live heap, fixture Bigarray storage and process peak RSS from cumulative allocation.
- [ ] Measure peak application-retained bodies and steady-state per-connection memory; kit has no borrowed Data API.
- [ ] Profile whole-head parsing: identify byte scanning, validated constructors, repeated field scans, buffering, result adaptation and allocation costs. Do not attribute the entire timing gap to validation.
- [ ] Compare whole-message public connection workloads with comparable validation policies; retain a behavior matrix when policies cannot match.
- [ ] Sweep header name/value lengths, case normalization, OWS, field count and target lengths at ordinary and limit-adjacent sizes.
- [ ] Add realistic route distributions: application-shaped shared prefixes, hot-route skew, misses, mixed methods, overlapping literals/parameters/wildcards and long/deep paths.
- [ ] Compare any production router change against the frozen array matcher with randomized differential tests; preserve declaration order and ordered/deduplicated Allow results.
- [x] Assert one stored slot per route and a prefix-segment node bound in the deep-index prototype; measure fallback-heavy construction.
- [ ] Establish reviewed production construction budgets and avoid repeated parsing of fallback candidates.

## P1: body protocol boundaries and failure costs

- [ ] Chunk extensions (token/quoted), legal trailers and trailer exposure/validation differences; isolate libraries without a comparable public trailer API.
- [ ] Truncated fixed/chunked bodies, malformed chunk sizes/delimiters, extra suffixes, overflow and quota boundaries, with explicit expected outcomes per library.
- [ ] HEAD, 204, 304 and informational responses: prove body suppression before comparing timings.
- [ ] Tunnel/upgrade handoff, unread suffix preservation and transfer of buffer ownership.
- [ ] Empty feed versus EOF, EOF after every structural boundary and completion exactly once.
- [ ] Backpressure under tiny output/event budgets; delayed readers/writers, body discard, cancellation and cleanup after errors.
- [ ] Long streams (16 MiB and larger), many tiny chunks, random binary bodies and mixed-size sequences without materializing whole messages in the harness.
- [ ] Resource exhaustion experiments on local bounded fixtures: measure retained memory and work limits, not just fast rejection.

## P1: application, runtime and API composition

- [ ] Routed Eio/Lwt endpoints under equal connection/concurrency/backlog limits with request latency distributions, goodput, errors and RSS.
- [ ] Keep-alive versus connection churn; TCP versus Unix sockets; local TLS as a separate measured layer.
- [ ] Slow clients, disconnects, cancellation storms and graceful shutdown with active uploads/downloads.
- [ ] Middleware construction versus invocation, short-circuit position, context record growth, heterogeneous Transition chains and asynchronous decisions.
- [ ] Router + Transition + body handler composition compared with independently measured primitives.
- [ ] Add Cohttp and framework-level comparisons only with a documented equivalent task; avoid ranking a full framework against a bare matcher/parser.
- [ ] API ergonomics fixtures: realistic upload/streaming/auth handlers, installed-consumer compile checks, error diagnostics and minimal adapter glue; code size is descriptive, not a performance score.

## P2: measurement quality and release evidence

- [ ] Reserved Linux ARM64/x86-64 hosts, CPU/power/frequency metadata and alternating old/new runs; keep shared CI advisory.
- [x] Calibrate batch duration, retain independent-process median intervals and mark short/noisy measurements unsuitable for ranking.
- [ ] Establish longer application steady-state and reserved-host warmup policy.
- [ ] Separate independent process variation from individual-operation/request latency; never report sample means as p99 latency.
- [x] Capture separately identified macOS stack sampling for the small-chunk body workload.
- [ ] Add Linux hardware-counter/flamegraph capture on reserved hosts.
- [ ] Establish reviewed workload-specific regression budgets for time, total memory and latency after stable baselines exist.
- [ ] Retain machine-readable catalogs, raw evidence and readable result summaries in CI; exercise missing/duplicate/incompatible measurement rejection.
- [ ] Run the user-owned long soak/campaign and independent review gates from M7; short benchmark success cannot close those gates.

## Completion rule

Every new lane needs a stated input/ownership contract, prebuilt fixtures where
appropriate, per-operation correctness checks, bounded runtime, retained raw
samples, clear units and comparison exclusions. Change this file as coverage
lands. Promote experimental optimizations only after both behavior and measured
tradeoffs support them; benchmark prototypes are not public APIs.
