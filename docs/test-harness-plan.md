# httpkit test harness: security, performance, and API ergonomics

Status: living implementation plan, originally written 2026-09-09 and updated 2026-09-10. M0–M6 implementation is complete: harness, core values, codecs, engines, adapters, and initial interoperability/performance lanes. M7 release tooling is implemented; full campaigns, extended experiments, and independent approval remain pending. See the [manual M7 checklist](m7-manual-checklist.md). Numbers below are proposed project policies and test budgets unless identified as implemented in the [package design](design.md); they are not performance or safety guarantees.

Navigation: [architecture and tools](#3-harness-components-and-dependencies) · [replay](#6-deterministic-scenarios-replay-and-shrinking) · [security matrix](#9-http1-adversarial-matrix) · [runtime adapters](#12-eio-and-lwt-adapter-conformance) · [performance](#15-performance-harness) · [API ergonomics](#16-api-ergonomics-as-executable-acceptance-criteria) · [CI tiers](#18-ci-tiers-reproducibility-and-budgets) · [implementation milestones](#20-implementation-sequence-and-concrete-gates).

## 1. Outcome and fixed boundaries

Build an executable specification for an OCaml HTTP toolkit before building its network-facing implementation. The harness must show that protocol behavior is correct, resource use is bounded, both runtime adapters honor the same contract, and independent users can compose the public primitives.

Established decisions:

- OCaml 5.5.0 only; immutable HTTP values and a deterministic, internally mutable sans-I/O engine.
- HTTP/1.1 client and server, streaming bodies, separate native Eio and Lwt adapters.
- Protocol code has no sockets, clocks, scheduler, global event loop, or application callbacks that can suspend.
- Request and response types are polymorphic in their bodies. Actual effectful body readers and writers belong to adapters.
- Codecs and engines must be independently usable. No common monad is required to implement another adapter.
- Application extensions and outbound client acceptance are tracked in the production-confidence roadmap. Railway owns public ingress, with optional Caddy; do not add backend protocol suites outside the HTTP/1 scope.
- A hand-written codec, a parser-library implementation, or selectively reused OCaml code can all implement the same harness subject. This plan does not silently settle that remaining implementation choice.

Success means reproducible evidence with explicit limits. A harness self-test passing is not evidence that an absent HTTP implementation is secure. Every report distinguishes harness health, implemented capability coverage, missing release capabilities, and actual subject results.

## 2. Threat model and security ownership

Assume a remote peer controls every input byte, its fragmentation, arrival times, connection closure, and whether it reads our output. A malicious server is as relevant as a malicious client. Applications can abandon bodies, throw exceptions, or misuse documented commands. An intermediary can parse the same bytes differently. Several independent connections may run on different domains.

| Boundary | Owner | Evidence required |
| --- | --- | --- |
| Field validation, serialization, message boundaries | HTTP values/codecs/engine | Invalid values cannot escape through normal constructors; framing has one interpretation |
| Retained buffers and backpressure | Engine plus adapter | Byte accounting and stalled-peer tests, including adapter queues |
| Clocks, cancellation, concurrency, connection admission | Runtime adapter | Virtual-time fault schedules plus real-runtime integration |
| Routing, authentication, trusted proxy configuration | Application or future sibling package | Core preserves needed information and does not invent trust |
| Encryption, certificates, DNS | Supplied transport or external library | Transport composition tests, without claiming cryptographic validation |
| Native dependencies and unsafe operations | Implementation maintainer | Dependency inventory and targeted memory-safety tests where applicable |

Use no untrusted network traffic or production captures in the baseline corpus. All peers and load targets are local test processes or isolated CI containers. Security findings are stored privately until triaged if they expose an unreleased vulnerability.

A plugin or adapter may change execution policy; it cannot override mandatory framing validation. Test-only instrumentation must not introduce a production switch that disables validation.

## 3. Harness components and dependencies

Use Dune, Alcotest for named deterministic cases, QCheck2 for generated properties and shrinking, and Crowbar with AFL instrumentation for coverage-guided fuzzing. Keep reusable model and invariant functions independent of all three runners. Use Bisect_ppx for a separate coverage build, MDX for executable documentation, and odoc for API documentation. These are development dependencies only. [Alcotest](https://github.com/mirage/alcotest), [QCheck](https://github.com/c-cube/qcheck), [Crowbar](https://github.com/stedolan/crowbar), [Bisect_ppx](https://github.com/aantron/bisect_ppx), [MDX](https://github.com/realworldocaml/mdx).

Implement the small sequential lifecycle model directly rather than adopting a framework for shared-memory linearizability. Our connection engine has one owner; deliberately racing its mutation across domains is outside its contract. Test adapters on real runtimes and run separate engine instances across domains. If a later public primitive claims concurrent shared access, add a dedicated linearizability suite at that point.

Proposed source organization:

```text
test/
  support/       scenario format, generators, shrinking, clocks, accounting
  model/         independent lifecycle model and invariant checks
  subjects/      public-API bindings for codecs, engines, Eio, Lwt
  self/          harness tests and intentionally faulty subjects
  contract/      requirement registry and deterministic protocol cases
  property/      generated values, bytes, schedules, operation sequences
  adapter/       deterministic transport tests and real runtime tests
  interop/       reference-program and reverse-proxy runners
  api/           external consumers, positive and negative compilation
  corpus/        reviewed seeds, minimized regressions, provenance
fuzz/            separate executables for each fuzz target
bench/           microbenchmarks, streaming, server load, result analysis
docs/            protocol policy, examples, coverage and release guidance
```

Only build harness layers needed for the current implementation milestone. Do not create empty passing test suites for future features. Test dependencies must never appear in installed production interfaces or dependency closures.

Verified local starting point: OCaml 5.5.0, Eio 1.4, Lwt 6.1.2, and an installed Dune 3.24.1 are present. The shell currently selects a Dune developer preview from a different directory. OCaml's compiler advertises `-afl-instrument`; `afl-fuzz` is not on PATH. Alcotest, QCheck, Crowbar, and Bisect_ppx were not in the installed package list. No installation or toolchain compatibility test has been performed for this plan.

Use Dune package management and version-controlled lock directories for exact compiler and dependency solutions. Declare direct dependencies in `dune-project` and generate the opam metadata. CI consumes `dune.lock/` for the sole supported compiler, OCaml 5.5.0; use released Dune 3.24.1 consistently. Pin repository and compatibility-overlay revisions, verify the normal and coverage locks, and include lock/workspace contents in evidence hashes. Mise manages the pinned opam executable; opam manages Dune in an isolated bootstrap switch; Dune manages the locked project compiler and dependencies. Include `mise.toml` in evidence hashes. Any incompatibility must be surfaced rather than silently raising the compiler minimum. The README and harness contract record the current implementation; the preceding paragraph is the original planning-time environment snapshot.

## 4. Contract registry and capability reporting

Give every normative rule and project policy a stable ID, such as `H1.FRAME.CL_TE`, `BODY.RETAINED_BOUND`, `ADAPTER.CANCEL.READ`, or `API.CORE.STANDALONE`.

Each registry entry contains:

- ID, concise rule, threat, layer, client/server applicability, and capability.
- Source section or explicit `project-policy` designation.
- Positive, negative, boundary, and state-transition case IDs.
- Which invariant or oracle establishes the result.
- Implemented, pending, or explicitly out-of-scope status, with rationale.
- Responsible subsystem and review requirement.

Required first-release capabilities: validated core values; request/response codecs; fixed-length and chunked streaming; trailers; persistence; handling of pipelined input with ordered responses; informational responses and Expect handling; EOF and early-response behavior; cancellation/close; HTTP upgrade and successful CONNECT handoff at the engine boundary; both runtime adapters. Actual WebSocket framing is out of scope. HTTP/1.0 compatibility is a separate declared capability, with explicit rejection tests until supported.

A capability becomes implemented only when its full associated suite runs against the real subject. Unsupported-feature tests do not count as implementation of that feature. A first-release readiness report fails while any required capability is pending.

Result states are `PASS`, `FAIL`, `NOT_IMPLEMENTED`, `UNSUPPORTED_PROFILE`, and `INFRA_ERROR`. Never coerce the last three into success. A milestone gate checks its enumerated capability set; the full release gate checks the entire required set.

Use the HTTP specifications as normative sources and record strictness choices separately. The relevant starting documents are [HTTP/1.1 messaging](https://www.rfc-editor.org/rfc/rfc9112.html), [HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110.html), and [URI syntax](https://www.rfc-editor.org/rfc/rfc3986.html). A registry entry must cite the exact section when implemented, rather than treating this plan as a substitute for the standard.

## 5. A stable subject boundary

The harness binds to the production public API through a thin subject module. The subject converts representations only; it must not repair invalid output, implement framing, drain extra input, retry rejected operations, or inject missing lifecycle behavior.

The normalized harness vocabulary is:

| Operation | Required observations |
| --- | --- |
| Create client/server with explicit configuration | Fresh identity and initial readiness |
| Offer input slice | Exact accepted prefix; caller retains the suffix |
| Report input EOF | Distinct from temporary lack of input or empty input |
| Submit application command | Accepted, backpressured, or typed error; acceptance cannot be ambiguous |
| Poll protocol event | Headers, body bytes, trailers, completion, error, handoff, or no event |
| Poll output | Stable pending byte slices, blocked, or closed |
| Acknowledge written prefix | Exactly that prefix is retired |
| Consume/release incoming body data | Capacity can be recovered without losing message identity |
| Abort or request graceful shutdown | Observable terminal behavior and resource disposition |

This vocabulary is a harness contract, not a mandatory set of production function names. Define concrete OCaml subject signatures in the first milestone, parameterized by abstract connection/request IDs and buffer representation. Use `result` or variants for expected errors. Unexpected exceptions always fail the test.

Pure engine operations do not call user I/O. Event polling never silently consumes socket data. Waiting is an explicit observation; it is not encoded as a loop that repeatedly polls until something happens.

Primary correctness tests are black-box public-API consumers. A separate instrumented build may expose aggregate counters: bytes retained, queued events, active messages, bytes examined/copied, and output acknowledgements. It must not expose parser internals to the reference oracle. Differentially run instrumented and normal builds on the same deterministic corpus to detect instrumentation-induced behavior changes.

## 6. Deterministic scenarios, replay, and shrinking

Use versioned JSON for serialized scenarios and JSON Lines for observations. Binary input is base64; sizes, IDs that might exceed JavaScript precision, and virtual nanoseconds are decimal strings. The in-process DSL is typed OCaml. Serialized scenarios contain data, not executable closures or shell commands.

A scenario records schema version, case/requirement IDs, role, capability profile, all limit values, application script, input chunks, transport readiness events, write allowances, body-consumption schedule, injected failures, virtual clock advances, seed, and generator version. A failure bundle additionally records source revision, dirty-tree content hash when applicable, compiler/dependency manifest, OS/architecture, command line, normalized observations, and the exact failing assertion.

Prefer materialized schedules over seed-only replay. Random generation may evolve or differ by compiler; the stored scenario must remain executable without regenerating it. Replay constructs a fresh subject and reruns the actions, then compares the result. Merely comparing two stored traces is not replay.

Define explicit steps for input arrival, EOF, read failure, write allowance, write failure, consuming a body chunk, accepting an application command, application failure, cancellation, graceful shutdown, clock advance, and bounded execution of runnable work. Each step has a monotonically increasing index. No real sleeps or wall-clock reads occur in pure tests.

Normalize request IDs by first appearance. Compare semantic headers, concatenated body bytes, trailers, completion/error classes, and message boundaries. Preserve repeated-header order. Do not erase distinctions such as raw targets, consumed suffixes, framing choices, or error-versus-success. Byte-exact serializer fixtures are a separate assertion class. Bounded large streams use a running digest and byte count; small regressions retain literal bytes for inspection.

For valid complete messages, compare cumulative consumed counts through the message boundary across fragmentations. For malformed input, distinguish the semantic error location from how much input an implementation accepted into staging before detecting it. Compare the documented error location/category and prove no following message is dispatched; do not manufacture an invalid invariance by equating staging consumption with the offending-byte offset.

Scheduling rules:

- Enumerate all partitions for fixtures of at most 12 bytes; enumerate every single split for selected fixtures up to 4 KiB.
- For larger fixtures, always test one-byte chunks, whole-buffer input, and splits around grammar delimiters and buffer boundaries; supplement with generated partitions.
- Explore all topological schedules of small event graphs with at most 8 events, subject to a 10,000-schedule per-case cap. Mark coverage partial if capped.
- Use seeded fair scheduling for larger scenarios. Fairness means an enabled participant is eventually selected; starvation scenarios are explicit separate cases.
- Track progress by bytes, events, state transitions, or external readiness. A blocked observation is allowed; repeated runnable steps without progress fail an operation budget.

Shrink failures in this order: remove unrelated connections/messages; remove actions while preserving prerequisites; reduce body and header content; simplify fragmentation; reduce limits and clock values toward boundaries. Preserve the failing requirement and error category. Bound shrinking to 60 seconds in PR jobs and 10 minutes nightly; always retain the original reproducer if reduction times out.

Replay of deterministic engine scenarios must produce the same normalized result 100 consecutive times. Real-runtime failures retain a controlled schedule and diagnostic trace, but do not claim exact OS scheduling replay.

## 7. Test the harness before trusting it

Implement a tiny correct fake subject and deliberately faulty variants. Self-tests must detect all these faults:

1. Dropping or duplicating a byte after a partial write.
2. Reporting more consumed input than was offered.
3. Treating an empty read as EOF.
4. Accepting a command twice when retrying after backpressure.
5. Emitting completion twice or emitting a body event after completion.
6. Reusing unread body bytes as a second request.
7. Retaining buffers above the configured budget.
8. Failing to wake a waiter on cancellation.
9. Moving a virtual deadline whenever a single byte arrives.
10. Polling forever with no progress.
11. Masking a message-boundary difference during trace normalization.
12. A shrinker deleting the action that made the original scenario valid.

Test scenario encode/decode, invalid schema versions, integer boundaries, binary round-trips, timeout enforcement, child-process crash reporting, and failing-test exit status. Ensure a missing or unselected suite is reported explicitly. Exercise deterministic generation for reproducibility and range boundaries; use established QCheck generation rather than a custom ad hoc PRNG.

For coverage-guided fuzzing, a known branching fixture must demonstrate differing coverage maps and a planted fault must be discoverable and replayable. A running fuzzer with no valid instrumentation is an infrastructure failure. OCaml documents compiler instrumentation for AFL; Crowbar's random mode alone does not establish coverage-guided fuzzing. [OCaml AFL guide](https://ocaml.org/manual/5.5/afl-fuzz.html).

## 8. Core value and serialization tests

Test every public constructor, accessor, update, comparison, and conversion. Expected invalid input returns a documented error, not an uncaught exception.

| Primitive | Required tests |
| --- | --- |
| Method | Standard and extension tokens; empty/invalid token; case preservation; no accidental case-insensitive equality |
| Status | Validated numeric range; known/unknown valid codes; formatting; reason text cannot inject a field or status line |
| Version | Supported wire encodings; unsupported-version error; future versions are never silently treated as HTTP/1.1 |
| Header name/value | Full byte-class boundary tests; CR/LF/NUL rejection; case-insensitive lookup; valid opaque value bytes remain intact |
| Headers | Empty, repeated, add/set/remove/get-all; deterministic order; separate Set-Cookie values; no universal comma joining |
| Target | All target forms; raw path/query preservation; malformed escapes; fragments; authority/port edges; no implicit double decoding |
| Request/response | Body polymorphism; map-body preserves metadata; immutable updates; validated construction |
| Body frames | Data/trailers/end ordering; empty data is not end; exactly one terminal completion |

For every accepted outbound value, check serialized bytes with independent fixed fixtures or a reference parser. Reject invalid outbound framing before emitting its headers. Once headers have been committed, later body failure must close/abort the exchange; the serializer cannot insert a fresh error response into an existing body.

Explicitly test HEAD-related response metadata, informational/final response distinction, and bodyless statuses without relying on a generic status-to-body heuristic. Keep semantic cases and exact-wire cases separate so permissible formatting differences do not obscure actual defects.

URI tests include escaped separators, percent-sign case, empty query versus absent query, dot segments, non-ASCII bytes, and repeated slashes. The HTTP core preserves the chosen raw representation; future routing normalization requires its own contract and tests.

## 9. HTTP/1 adversarial matrix

Build a table-driven corpus by family. Every family has accepted input, rejected input, truncation, fragmentation, exact-boundary, and resource-limit variants where meaningful. Test client and server independently; do not rely only on wiring our own client to our own server.

### Proposed strict policy

Use one named strict profile initially. Reject bare-LF line endings, obsolete folded headers, whitespace before field-name colons, duplicate Content-Length fields even when equal, comma-list Content-Length, and combined Transfer-Encoding plus Content-Length. Reject unsupported transfer-coding chains. Accept extension methods that pass token validation. Preserve allowed opaque field bytes. Do not add a permissive profile during the initial release.

These are project policy choices to encode explicitly, including stricter rejection where a standard permits recovery. They are not assertions that every other compliant implementation must behave identically. Do not conflate representation-level header preservation with semantic processing of a particular field.

| Family | Corpus dimensions and assertions |
| --- | --- |
| Start lines | Missing separators, extra whitespace, invalid bytes, empty target, oversized line, unsupported version, invalid status |
| Line termination | CR/LF split across calls; lone CR/LF; doubled CR; EOF between terminators; obsolete continuation |
| Field names | Empty name, separators, embedded controls, whitespace before colon, mixed case, long common prefixes |
| Field values | Embedded line breaks/NUL, allowed opaque bytes, leading/trailing permitted whitespace, empty value, long repeated values |
| Host/authority | Missing/duplicate/invalid Host, origin versus absolute target, conflicting authorities; validation before dispatch |
| Length fields | Zero; leading zeros; sign; junk suffix; multiple values; conflicting/equal duplicates; decimal overflow |
| Transfer coding | Case/whitespace variations; duplicate chunked; non-final chunked; unsupported coding; mixed length headers |
| Chunk sizes | Hex boundaries, huge numbers, invalid digits, overflow, split size lines, missing delimiters |
| Chunk extensions | Empty/malformed quoted values, escaped bytes, repeated extensions, unbounded extension line attack |
| Trailers | Empty section; duplicates; undeclared/forbidden fields under documented policy; size/count limits; missing final delimiter |
| Body truncation | EOF at every position of fixed/chunked bodies; advertised length smaller/larger than emitted data |
| Message chaining | Two/three requests in one read; body contains a fake start line; malformed request followed by valid marker request |
| Responses | Informational sequences, final response, HEAD, 204/304, close-delimited body, unsolicited/extra response |
| Expectations | Continue accepted/rejected, early final response, body arriving before continue, unsupported expectation, repeated informational responses |
| Persistence | Close tokens, half-close, next request before previous response completes, shutdown while idle/active |
| CONNECT/upgrade | Acceptance/refusal, unsolicited switching response, buffered post-handshake bytes, output flush before handoff |
| Wrong protocol | Unsupported HTTP versions, TLS bytes, arbitrary binary bytes; no accidental request dispatch |
| Outbound misuse | Conflicting framing, body length mismatch, invalid trailer, second final response, stale message ID |

Each rejection fixture checks more than the error code: accepted-byte prefix, whether application headers/body were exposed, whether output was committed, whether connection reuse is forbidden, and whether trailing bytes can ever be dispatched.

For invalid headers or framing discoverable before header completion, require zero handler invocations. For errors discovered after streaming begins, require no successful body completion, prompt reader failure, and correct connection disposition. The library cannot roll back application effects performed before a late body error; documentation and examples must make this visible.

Known-dangerous field combinations receive explicit hand-authored fixtures before generated variants. Keep the parser oracle outside the production parser: fixed expected outcomes for small cases and independently maintained reference programs for broader comparison.

## 10. State machines, ownership, and backpressure

The reference model describes lifecycle facts, not a second implementation of the wire parser. Track per-message phase, ordered outstanding identities, body completion, response commitment, input EOF, pending output, shutdown/handoff status, and externally owned resources.

Generate valid command sequences from model preconditions. Generate misuse sequences separately so invalid-command noise does not dominate deep valid-state exploration. Cross-check every observed action against the model after every step.

Required lifecycle cases:

- Response before request-body consumption; explicit body discard; abandonment; discard blocked by a peer; safe close rather than reinterpreting unread bytes.
- Incoming body demand paused while outgoing response progresses, and the reverse. No global lock held across a blocking read/write.
- Backpressured command retried after readiness; prove exactly-once acceptance and data delivery.
- Responses remain ordered for pipelined input. Bound admission; a serial implementation may stop consuming later requests without losing the unread suffix.
- Client cancellation before any request bytes, during headers/body, and after response headers. Never transparently replay a potentially side-effecting request.
- Server shutdown stops admission, completes allowed in-flight work, and closes at the configured deadline. Failure after output commitment does not emit a second response.
- Handoff occurs once and only after necessary HTTP output has been acknowledged. Both transport ownership and buffered residual input transfer together.
- Invalid IDs, repeated finish/abort, commands after terminal state, and acknowledgements outside the offered output range fail deterministically without corrupting another message.
- A normal transport close is idempotent at adapter cleanup boundaries. It must not hide an earlier error.

Buffer contract tests:

- Start with copying/owned immutable chunks as the harness baseline. A future borrowed-buffer capability gets a separate explicit contract and suite.
- Mutate or reuse caller input after `offer` returns; already accepted data remains correct under the copying contract.
- Pending output remains valid until acknowledged. Repeated polling does not allocate a fresh copy or change its bytes unnecessarily.
- A borrowed-buffer implementation, if later added, documents invalidation points and release tokens; test mutation, delayed acknowledgement, GC pressure, and early cancellation around those points.
- Validate slice offset/length boundaries, zero-length slices, integer overflow, and lengths larger than backing storage. Never convert untrusted int64 lengths to native `int` before checking.
- Track Bigarray/native retention separately from OCaml heap words when relevant. Heap allocation alone is not a total-memory measurement.

Backpressure is a whole-path invariant: parser staging + engine queues + adapter queues + current transport buffers + application-held leases must be accounted for separately. Report engine-controlled retention and the application-visible retention obligation. A user explicitly retaining all received data is outside the engine's memory bound, and must not be concealed in benchmarks.

## 11. Resource limits and timeout profiles

Create tiny-limit profiles to reach boundaries cheaply, and a realistic reference profile for examples and integration tests. Every limit is tested at zero if legal, one, limit minus one, limit, limit plus one, maximum representable value, and invalid configuration. Configurations with impossible internal relationships fail construction.

The following reference profile is a proposed initial convenience-adapter default, subject to explicit API review. All limits are configurable; tests always record their actual values.

| Resource | Reference value | Enforcement |
| --- | --- | --- |
| Request/status line including terminator | 8 KiB | Incremental codec |
| Entire header section including delimiters | 32 KiB | Codec before further retention |
| Header fields | 100 | Codec |
| Trailer section / fields | 16 KiB / 64 | Codec |
| Chunk-size line including extensions | 1 KiB | Codec |
| Engine-owned queued incoming body data | 64 KiB | Engine stops accepting body bytes |
| Engine-owned queued outgoing data | 64 KiB | Command backpressure before excess retention |
| Adapter staging per direction | 16 KiB | Adapter read/write loop |
| Active exchange admission per connection | 1 by default | Later pipeline bytes remain unread |
| Informational responses per exchange | 16 | Engine rejects excessive sequences |
| Buffered collect-body helper | 1 MiB, caller-overridable | Helper fails before appending excess data |
| Total streamed body size | No mandatory core cap | Adapter/application may set a byte quota; bounded buffering is mandatory |
| Header completion deadline | 10 seconds | Absolute adapter deadline; byte trickles do not reset it |
| Body read / output write idle deadline | 30 seconds | Adapter tracks actual progress |
| Keep-alive idle deadline | 30 seconds | Adapter |
| Graceful shutdown deadline | 10 seconds | Adapter |
| Server connection admission | 1,024 active connections per server instance | Adapter; finite configurable bound |

Metadata, queues, timers, and fixed buffers are counted in addition to payload budgets. Require a documented linear bound of the form `fixed + header budget + trailer budget + incoming budget + outgoing budget + adapter staging + per-admitted-message metadata`. Measure the constants once implemented; do not pretend the sum of payload limits is total process RSS.

Long-lived streaming may explicitly disable an idle deadline or use application heartbeats. This must not disable byte budgets or header-completion protection. Total body-duration and minimum-rate policies remain optional adapter policies, tested when configured. No hidden clock reads enter the engine.

Limit behavior must be consistent under fragmentation. Use synthetic huge advertised lengths without allocating huge payloads. For cumulative length overflow, advance a test counter/model or stream repeated bounded chunks; distinguish model arithmetic tests from full payload integration tests.

Test CPU denial of service using long shared header prefixes, many tiny chunks, repeated informational messages, rejected-command loops, malformed input near size limits, and one-byte delivery. Bound both per-call work and accumulated work for growing workloads.

## 12. Eio and Lwt adapter conformance

Share scenario data, expected semantic events, and transport scripts. Implement runtime-specific drivers; do not introduce an artificial shared promise/effect abstraction into production solely to simplify tests.

The fake duplex transport supports independent directions, bounded buffers, short reads, partial-write behavior at the appropriate API layer, EOF, read/write errors, readiness notifications, and explicit ownership. Eio flow operations that promise full writes must retain that contract; simulate partial system writes below them or use the engine-level transport seam. Do not make mocks violate real API contracts.

Use two cancellation outcomes where the runtime race permits them: completed before cancellation, or cancelled before completion. In either outcome cleanup must occur exactly once. A cancelled operation must not later publish a second success, and user cancellation must not be converted into an ordinary successful EOF.

Eio tests use explicit mock clocks and flows, running in a switch with tracked child fibers. Its mock clock can advance to scheduled events without sleeping. Lwt tests use explicitly controlled promises and an injected clock/sleep capability; every created test promise and cleanup action is registered. These are adapter injection seams, not a runtime abstraction in the HTTP core. Eio's existing mocks demonstrate this testing approach. [Eio testing documentation](https://github.com/ocaml-multicore/eio#testing-with-mocks).

For each adapter run:

- Cancellation before and during read, write, body wait, handler execution, queue admission, and graceful shutdown.
- Handler exception before headers, after headers, and while producing a body.
- Peer EOF/reset while readers/writers are pending; simultaneous cancellation and completion.
- Deadline immediately before, exactly at, and after readiness. The controlled test scheduler orders equal-time events explicitly; the real runtime may take either documented race outcome but must never leak or complete twice.
- Stalled producer with active consumer, stalled consumer with active producer, and duplex progress needed to avoid deadlock.
- Consumer stops reading or returns an early response; bounded discard or close completes according to policy.
- Resource acquisition partially fails; accepted socket or child task is cleaned up.
- Connection admission exhausted; backlog and failure behavior remain bounded.
- Graceful shutdown with idle connections, active upload/download, and a permanently stalled peer.
- Two connections use identical local request IDs; metadata and responses never cross between them.

Per-test cleanup assertions count live fibers/tasks, registered timers, owned transports, pending wakeups, body waiters, and retained buffer leases. Use process-level open-descriptor checks in socket tests as additional evidence; avoid claiming our task registry detects every internal runtime allocation.

Use real `Eio_main` and real Lwt event-loop tests over loopback sockets and socket pairs in addition to mocks. Parent/child readiness handshakes replace startup sleeps; bind ephemeral ports and discover the assigned port. A parent process watchdog terminates hangs and reports the last observed action. Native tests include TCP half-close and reset where the OS supports deterministic injection.

Run independent connections on 1, 2, and 4 domains in stress jobs. Do not concurrently mutate one engine instance unless a future API explicitly permits it. Test cancellation reaches owned children and that no untracked background loop survives server shutdown.

## 13. Fuzzing plan

Provide nine separately invocable targets:

1. Core value constructors and serializer validation.
2. Incremental request codec.
3. Incremental response codec with originating-method context.
4. Chunked body and trailer codec.
5. Server commands plus input/events.
6. Client commands plus input/events.
7. Partial writes, acknowledgements, and buffer lifecycle.
8. Deterministic adapter transport/cancellation schedules.
9. Cross-connection isolation and retained-resource accounting.

Use both arbitrary bytes and grammar-aware generation. Structure-aware mutations vary lengths, delimiters, header duplication, targets, and command dependencies. Avoid a generator dominated by trivially rejected first bytes. Track valid-header and completed-message rates, maximum reached lifecycle phases, and capability coverage to make shallow exploration visible.

Default small fuzz workload: at most 64 KiB encoded scenario, 1,024 actions, 8 exchanges, and 4 connections. Separate large-limit targets use up to 1 MiB input and 4,096 actions. Per-process defaults are 512 MiB RSS limit and a two-second input watchdog for small targets; large-target limits are 1 GiB and five seconds. Calibrate timeouts in the toolchain smoke milestone with known valid worst-case fixtures; any adjustment is recorded, never a blanket timeout exemption.

Compile all first-party code under test with AFL instrumentation and verify map activity. First try Crowbar with the selected Linux AFL++ toolchain and record compatibility evidence. If its persistent integration is incompatible, use the same target core in a file-per-execution AFL runner with native OCaml instrumentation. A missing instrumented runner blocks the fuzz milestone; ordinary random mode remains useful but is labeled separately.

Seed the corpus from hand-written boundary cases, accepted minimal exchanges, minimized properties, and reviewed upstream regressions. Record original URL, commit, license/provenance, affected capability, and expected behavior for imported material. Never blindly copy an upstream fixture's expected outcome into our strict policy.

After every finding: retain original bytes/schedule, reproduce without instrumentation, minimize, classify crash/hang/resource/semantic/tooling failure, fix or explicitly triage, add deterministic regression, then add the minimized seed. Do not catch arbitrary exceptions and label them expected parser rejection. Persistent fuzz iterations must reset all subject and harness state; run an A/B/A test to detect cross-input contamination.

CI limits contain accidental resource abuse; they do not prove algorithmic bounds. The deterministic resource suite supplies separate accounting evidence.

## 14. Differential and intermediary testing

Build small reference executables around pinned Hyper and httpun versions. Exchange normalized observations through bounded JSON Lines, with raw bytes stored separately. Keep references out of production dependencies. They provide independent implementations, not a majority-vote oracle.

For each discrepancy, classify it as an actual defect, an intentional strict-policy difference, unsupported reference capability, or an unresolved discrepancy. An unresolved framing/message-boundary discrepancy blocks the affected release capability. Allowlisted differences require a fixture, policy/source explanation, and exact reference version.

Add isolated reverse-proxy lanes for HAProxy and nginx, with exact image digests and committed configurations selected during toolchain setup. Test both forwarding to our server and receiving responses from our server. Keep direct-engine, direct-socket, and proxy results distinct.

Use three observers: controlled raw sender, proxy wire/backend observer, and application invocation recorder. Compare how many messages were forwarded, consumed, dispatched, and answered. Marker requests after malformed input must never appear as unexplained additional application requests. A proxy rejecting traffic before our engine sees it proves only proxy behavior; record that explicitly.

Test connection reuse on/off, upstream buffering on/off where supported, normal and chunked messages, repeated fields, early rejection, trailers, close behavior, and handoff configurations. Every dangerous ambiguity family receives direct raw-socket coverage regardless of what a proxy normalizes.

References and proxies run in bounded child processes with no external network access during the test. Do not use an external site's behavior as a conformance oracle. Adding another intermediary later adds a named tested configuration, not a claim of universal interoperability.

## 15. Performance harness

Performance has three independent dimensions: CPU/allocation efficiency, bounded behavior under pressure, and application-visible latency/throughput. Report each separately. A faster benchmark does not excuse a conformance regression or an ergonomically unsafe ownership contract.

### Workload inventory

| Workload | Sizes / variants | Primary measurements |
| --- | --- | --- |
| Core headers | 0, 8, 32, 100 fields; repeated names; mixed case | Construction, lookup, iteration, updates; allocations |
| Parse and serialize | Small GET; response; 1 KiB/8 KiB/limit-size headers | ns/message, bytes/s, allocation/message |
| Fragmentation | Whole input; 1, 7, 64, 1,024, 16,384-byte chunks | CPU per byte, bytes rescanned/copied, allocation |
| Message framing | Empty; known length; unknown/chunked; trailers | CPU and allocation per message/body byte |
| Streaming | 1 KiB, 64 KiB, 1 MiB, 64 MiB, then 1 GiB generated stream | Throughput, peak retained bytes, RSS plateau, GC |
| Partial output | Full writes; one byte; variable writes; long blocked periods | CPU, copies, no busy loop, exact output |
| Persistent connections | 1, 100, 10,000 sequential requests | Retention drift, latency, amortized allocations |
| Concurrent connections | 1, 16, 128, 1,024; single and multiple domains | Fairness, memory/connection, throughput, tails |
| Adversarial valid input | Tiny chunks; maximum headers; repeated fields | Work scaling and budget enforcement |
| Invalid input | Immediate failure versus failure at configured boundary | Time/allocation to reject and cleanup |
| Cancellation churn | Repeated interrupted upload/download and shutdown | Resource return, memory trend, cancellation latency |
| Mixed traffic | Small requests alongside large or stalled streams | Tail latency and absence of starvation |

Generate large bodies incrementally. Never preload a 1 GiB fixture then attribute its RSS to the engine. Confirm byte counts/digests outside timed regions where possible; ensure work cannot be optimized away. Publish whether checksums, copies, connection setup, and fixture construction are inside each measurement.

### Deterministic performance assertions

- Retained payload never exceeds the configured component budgets. Admission includes the incoming fragment rather than allowing one arbitrary oversize buffer past the bound.
- No runtime worker repeatedly polls an unavailable engine/transport; count calls while readiness is withheld.
- Streaming retained state depends on configured queue limits and admitted exchanges, not cumulative body length.
- Readiness notification and completion bookkeeping do not grow with already-completed exchanges.
- Engine byte-work counters should scale linearly with bytes plus calls/events. For geometric workload sizes, use an initial upper growth factor of 2.5 when input doubles, after subtracting fixed setup and keeping call/byte ratio fixed. A failure requires investigation; do not dismiss it based on wall-clock noise.
- Exercise relevant paths at 4, 8, 16, 32, and 64 KiB with raised test limits. Count rescans, copies, and comparisons separately where instrumentation exists.

These counters require documented definitions and cross-checks against external allocation measurements. They diagnose particular paths; they are not a proof of universal linear time.

Apply the linear-work gate to incremental codec scanning, framing, streaming, and lifecycle bookkeeping. Header collection construction/update/lookup has its own declared complexity and benchmark family; do not assume every operation on every chosen persistent representation is constant-time. Counters required for a hard complexity gate must be implemented before that gate can pass.

### Microbenchmark procedure

Use an uninstrumented release build, monotonic clock, `Gc` allocation counters, and process-level memory metrics. Keep benchmark dependencies outside production libraries. Optional memory tracing is a diagnostic lane only and must not become a prerequisite for supported compiler versions.

For each benchmark: warm up for 3 seconds; calibrate a batch to at least 250 ms; gather 30 batches; record all raw samples. Fixture creation happens before timing unless creation is the operation being measured. Do not force a GC inside an operation under test. Allocation accounting subtracts known harness overhead using an empty control run, with raw and adjusted numbers retained.

Record minor/major allocation, collections, promoted words, elapsed time, messages/bytes processed, and peak external/native-buffer retention. Long-running tests run in a separate process so previous cases do not contaminate retained-memory measurements.

### End-to-end load procedure

Use a separate load-generator process, and a separate host for publishable network capacity numbers when available. Pin client/server CPU sets and record CPU topology, frequency policy, OS/kernel, architecture, compiler flags, GC settings, dependencies, transport buffers, and resource limits. Otherwise label loopback numbers as such.

Run both fixed-concurrency and fixed-arrival-rate tests. Use wrk2 for compatible constant-rate HTTP fixtures; scripted protocol scenarios remain custom harness jobs. Constant-rate measurements must account for intended send time, not only the time a busy generator finally sent a request. This avoids hiding overload latency through coordinated omission. [wrk2 methodology](https://github.com/giltene/wrk2).

Start with a capacity sweep, then run fixed offered rates at 25%, 50%, 75%, 90%, and 110% of the baseline implementation's measured sustainable throughput. Use the same absolute offered rates for a candidate comparison. Warm up 10 seconds and measure 60 seconds per run, with five paired runs for release comparisons. Define sustainable throughput as the highest tested rate with at least 99.9% successful responses and no continuously growing in-flight backlog over the measurement period.

Report intended/actual arrival rate, successful throughput, errors/timeouts, queue growth, CPU utilization, memory, and p50/p95/p99 latency. Report p99.9 only with at least 1,000,000 observed requests and disclose sample counts. Timeouts and dropped requests stay in the outcome report; they cannot disappear from the latency story. If the generator saturates, the result is invalid rather than a server limit.

Control socket options, keep-alive, body sizes, admission limits, and worker/domain counts across compared implementations. Hyper/httpun throughput is contextual evidence, never an acceptance gate when feature/configuration equivalence cannot be established.

### Regression policy

Correctness and hard resource limits are mandatory on ordinary CI. Timing regressions are advisory on shared runners. They become release gates only on a designated stable runner with measured repeatability.

Compare the last accepted baseline and candidate in alternating order on the same runner. Establish baseline repeatability with three full sessions; median-time variation must be within 3% for a gated microbenchmark. A noisier benchmark is labeled advisory until its setup is fixed.

Initial practical regression thresholds: median operation time +5%, allocation/message +5%, steady streaming RSS +10%, successful throughput -5%, and p99 latency +10% at the same sub-saturation offered load. The measured change must exceed both the practical threshold and a paired 95% bootstrap confidence interval excluding no regression. Allocation changes must also exceed one word per operation; RSS changes must also exceed 1 MiB. Hard queue limits have no statistical exemption.

Group related benchmark variants into predeclared gating families to avoid cherry-picking. Investigate a flagged family with a fresh paired session; do not rerun indefinitely until it passes. A baseline update is a reviewed change containing rationale and raw evidence. Security fixes may justify a measured slowdown, but the tradeoff remains explicit.

Initial absolute throughput promises are intentionally absent. Once a correct implementation exists, baseline collection supplies evidence; it cannot certify competitiveness before measurement.

## 16. API ergonomics as executable acceptance criteria

The harness must test the library as a downstream author sees it. Build consumer fixtures in isolated Dune projects against installed packages, with no repository-private include paths or test-support dependencies. Archive the source and compiler output on failure.

Required consumer fixtures:

| Consumer | Acceptance criterion |
| --- | --- |
| Types-only application | Construct/update requests and responses without linking a protocol engine or runtime |
| Codec-only application | Parse/serialize a complete example incrementally without sockets or scheduler |
| Manual engine driver | Drive a complete exchange over in-memory byte queues using only documented public APIs |
| Eio server and client | Direct-style handlers; explicit switches/flows; streaming and cancellation work |
| Lwt server and client | Promise-style handlers; streaming and cancellation work without Eio |
| Third-party transport | A small scripted transport works without editing httpkit or instantiating a universal I/O monad |
| Shared pure transformation | The exact same request/response transformation module is used by both adapter examples |
| Streaming transformer | Bounded chunk transform and trailer forwarding; no collect-all helper required |
| Framework-like assembly | Hand-written dispatch plus one pure header transformation composed outside the engine; no router package required |
| Wrapped transport | Existing flow wrapper can supply decrypted or transformed bytes without the engine knowing its origin |
| Error recovery | Before-commit handler failure, after-commit body failure, and cancelled body are demonstrated distinctly |
| Handoff consumer | Receives the transport and residual bytes exactly once through the documented upgrade path |

Do not infer TLS correctness from the wrapped-transport fixture. It checks composition only.

Ergonomic rules to test and review:

- Core requests accept a user-defined body type without conversion to an Eio or Lwt type.
- Pure transformations do not require functors over execution, promises, or effects.
- Convenience APIs compose from documented lower-level operations. Reimplement one small convenience flow in a consumer fixture to prove that boundary.
- Routine examples require no `Obj.magic`, unsafe constructor, private module, PPX, code generation, or dynamic global registry.
- No hidden runtime starts, socket opens, environment reads, or process exits during library initialization. An isolated core consumer verifies this behavior and links without Unix/Eio/Lwt runtime libraries.
- Linking the Eio adapter must not require the Lwt promise runtime; distinguish that from legitimate transitive utilities such as `lwt-dllist`. Linking the Lwt adapter must not require Eio.
- Body EOF, trailers, failure, cancellation, and ownership are distinguishable in public types or documented operations.
- A slow consumer can apply backpressure without understanding parser internals.
- The error type identifies category and location/phase without exposing unbounded raw input or secrets.

Positive compilation tests cover public module access, body polymorphism, and both native handler styles. Negative compilation tests verify that abstract validated representations cannot be forged through their normal representation and that an Eio handler cannot accidentally satisfy a Lwt handler signature. For invalid header strings, rejection is a runtime constructor test, not a compile-time guarantee.

Negative tests assert compilation fails at the intended use site and include a recognizable type/module name. Avoid golden snapshots of entire compiler diagnostics across OCaml versions. Also keep a positive counterpart so a broken fixture environment cannot make every negative test appear successful.

Run MDX examples and standalone examples in CI. Keep deliberate non-compiling examples explicitly marked. Generate odoc and fail unresolved first-party references. Check first-party exported interfaces for unintended runtime/test-library types. Review public `.mli` diffs as API changes, with migration notes for changes after the first published release.

Human ergonomics review remains necessary. At each public-interface milestone, have a reviewer perform three tasks using only installed packages and docs: write an in-memory exchange, stream a response, and handle cancellation. Record undocumented steps, confusing errors, redundant conversions, and hidden ownership obligations as defects. Do not use lines-of-code or compilation success as a substitute for usability. Target a 30-minute review session; the timebox is a discovery method, not a benchmark score.

## 17. Coverage, mutation, and independent review

Maintain three separate coverage reports:

1. Contract coverage: every supported requirement has positive/negative/boundary evidence where meaningful.
2. State coverage: valid transitions, terminal paths, and invalid commands exercised.
3. Instrumentation coverage: Bisect expression points reached by tests.

Do not label expression coverage as branch coverage, and do not claim 100% coverage proves correctness. Initially require 100% mapped required contract entries and documented coverage of every supported lifecycle transition. At release, target at least 95% instrumented points in first-party core/codec/engine code, with reviewed justifications for exclusions; adapter paths are assessed by transition/fault coverage as well as point coverage.

Maintain a targeted mutation set: remove a framing rejection, permit one excess buffered byte, fail to decrement retained-byte accounting, omit a cancellation wakeup, duplicate completion, and accept stale IDs. Apply mutations in isolated disposable copies during dedicated jobs, never to the working checkout. Every curated mutation must be killed by a named test. This is a gate for known protections, not a claim of exhaustive mutation coverage.

Require a second reviewer for framing, buffer ownership, cancellation, and limit changes before an internet-facing release. The reviewer checks oracle independence and whether the test fails on the prior/broken behavior. Automated or AI review can supplement this; external security review remains separate evidence.

Any reused parser/engine code gets an upstream provenance record and a maintained review queue for upstream security fixes. Dependency checks report updates and advisories; they do not automatically update the implementation or corpus.

## 18. CI tiers, reproducibility, and budgets

Use separate build directories/profiles for normal, coverage, fuzz, and benchmark builds. Reusing instrumented artifacts in a performance job invalidates its results. CPU-heavy lanes run in isolation from timing benchmarks.

| Tier | Trigger / environment | Required work | Initial budget |
| --- | --- | --- | --- |
| Local fast | Explicit developer command | Harness self-tests, deterministic regressions, API fixtures, 200 cases/property | Aim for <60 s after build |
| PR correctness | Linux x86-64, OCaml 5.5.0 | Full deterministic corpus, 1,000 cases/property, adapter mocks, API/install isolation | 10 min per compiler, excluding cold install |
| PR native | Linux 5.5.0 and macOS arm64 5.5.0 | Real socket tests for both adapters, 100 cancellation schedules/scenario family | 10 min/job |
| PR fuzz smoke | Linux 5.5.0 | Instrumentation self-test, all regression seeds, 30 s per implemented fuzz target | About 5 min fuzz CPU plus build |
| PR perf smoke | Ordinary Linux runner | Correct output, hard bounds, benchmark execution, advisory timing | 5 min |
| Nightly | Linux 5.5.0 | 10,000 cases/property; 10,000 lifecycle schedules; 20 min/target fuzzing; coverage; intermediary suite | Up to 3 h fuzz CPU plus suites |
| Weekly | Isolated Linux/macOS workers | 2 h/target fuzzing; 2 h mixed-load soak per adapter; domain stress; mutation suite | Explicit longer job |
| Release candidate | Pinned manifests and stable runner | Full matrix; 8 h/target fuzz campaign; interop; API review; paired benchmark sessions | Up to 72 h fuzz CPU plus other work |

These are future CI schedules, not automations created by this plan. Dedicated hardware/cloud spending is not provisioned here. Until a stable performance runner exists, timing results remain advisory and the performance release gate is `INFRA_ERROR/NOT_READY`, never silently passed.

Counts are per implemented property/target. Print scheduled, executed, discarded, and failed counts. If generated preconditions discard more than 10% of cases, fail the generator-quality check and fix the generator. A budget timeout reports incomplete work rather than truncating case counts to green.

Run small deterministic parser/constructor suites in native and bytecode builds. Add a Linux arm64 compile/test lane before claiming Linux arm64 support; macOS arm64 alone does not establish that. The initial tested support matrix is Linux x86-64 plus macOS arm64. Other architectures, 32-bit execution, Windows, and browser compilation are not claimed by this release.

PR jobs use fixed published seeds plus one seed derived from the source revision; nightly jobs add rotating seeds and materialize every failure. Keep dependency/opam repository revisions, container digests, upstream reference commits, locale, timezone, and test profile in manifests. Do not rely on whatever latest dependencies CI happens to resolve.

Before a required capability exists, CI reports its pending status without claiming full readiness. A milestone-specific job may pass when its own scope is complete. Full-release reporting always enumerates remaining requirements.

## 19. Developer commands and failure artifacts

Implement one development-only runner named `httpkit-test` that dispatches suites and writes a consistent report. The following are planned commands; they do not exist yet:

```sh
httpkit-test doctor
httpkit-test run --tier fast
httpkit-test run --suite contract --case H1.FRAME.CL_TE
httpkit-test run --suite property --seed 42 --count 1000
httpkit-test run --suite adapter --runtime eio
httpkit-test run --suite adapter --runtime lwt
httpkit-test replay path/to/scenario.json
httpkit-test shrink path/to/scenario.json
httpkit-test fuzz --target request-codec --seconds 1200
httpkit-test bench --profile micro --output path/to/results
httpkit-test compare --baseline path/to/baseline --candidate path/to/results
httpkit-test readiness --milestone M3
httpkit-test readiness --release
```

`doctor` reports executable paths/versions, supported compiler, dependencies, AFL coverage smoke status, available native/reference tools, and profile prerequisites. It does not install tools or modify the user's global environment. Dune aliases call the same runner for `runtest`, API, coverage, fuzz-smoke, and benchmark-smoke tasks; document aliases as they are implemented.

Each failure directory includes:

- Original and minimized scenario, schema version, case and requirement IDs.
- Expected/actual normalized observations and first divergence.
- Escaped byte context with offsets and message/connection identity.
- Resource counters, virtual clock and readiness state, and pending operations.
- Runtime exception/backtrace or child-process termination details.
- Exact reproducible command and source/toolchain manifest.
- Corpus provenance and minimizer outcome.

The artifact loader is also an input boundary: cap encoded scenarios at 8 MiB, JSON depth at 32, and actions at the selected profile's limit. Large streams are represented by bounded deterministic repeat instructions, never embedded gigabyte strings or executable code. Unknown schema versions, invalid base64, invalid sizes, and unsafe case IDs fail decoding. Construct artifact paths from generated IDs inside a dedicated directory; peer bytes never become filenames, format strings, or shell fragments. Cap normal traces at 10 MiB and retain the first and last relevant events with a truncation marker.

Console output begins with the violated contract and reproduction command. Detailed traces are artifacts, not a wall of routine success output. Escape control sequences and bound all diagnostic fields. Synthetic credentials use unmistakable placeholders. Real secrets are redacted from human logs; if a raw sensitive reproducer is necessary, keep it in a restricted artifact store rather than a public CI attachment.

Machine-readable JSON report and JUnit XML accompany the human summary. Correctness tests exit nonzero on failure or a missing required capability. Distinguish exit codes for test failure, infrastructure failure, and incomplete required scope. A passing local milestone must never be mistaken for release readiness.

Keep ordinary successful reports for 30 days and benchmark baselines/release manifests for the release lifetime. Preserve minimized regressions in the repository permanently. Keep security findings private until disclosure policy allows publication; pin any restricted artifacts by digest in the private tracking system.

## 20. Implementation sequence and concrete gates

Implement in this order. Each milestone adds real evidence and is independently reviewable; do not wait for a complete HTTP implementation to test the infrastructure.

| Milestone | Deliverables | Completion gate |
| --- | --- | --- |
| M0: Toolchain and contract | Isolated build setup, requirement registry, subject signatures, capability manifest, pinned dependency solutions | Both compiler builds work; AFL coverage fixture works; pending HTTP capabilities are clearly reported |
| M1: Harness kernel | Typed scenario DSL, JSON codec, virtual scheduler, replay/shrinking, fake transports, accounting, faulty subjects | All curated faults detected; replay executes fresh subjects; watchdog and missing-suite reporting verified |
| M2: Core values | Real core subject, boundary corpus, constructor properties, installed-consumer fixtures, initial microbenchmarks | Types-only use works without runtime; invalid serialization inputs fail; no core capability pending |
| M3: Codecs and framing | Real codecs, independent fixtures, fragment matrix, framing corpus, initial reference runners, codec fuzz targets | Required codec rules pass; instrumented/noninstrumented behavior agrees; adversarial limits hold |
| M4: Engines | Client/server subjects, lifecycle model, stateful fuzzing, body ownership and partial-write suites | Both roles pass lifecycle, exact-byte accounting, handoff, and bounded-stream tests |
| M5: Runtime adapters | Eio then Lwt subject bindings, mock-clock cases, real sockets, failure cleanup | Same conformance scenarios pass for both; no resource leaks or hidden runtime dependencies in examples |
| M6: Interop and performance | Proxy lanes, mixed workloads, memory/complexity reports, stable-runner baselines | Framing discrepancies resolved; bounds pass; baseline quality known; limitations explicitly reported |
| M7: Release evidence | Full capability report, independent review, docs/install matrix, release fuzz campaign, vulnerability process | All release gates complete with source-matched artifacts; otherwise release remains unready |

For every feature PR, require: the contract entry; smallest deterministic regression/positive case; appropriate property/model coverage; resource-limit behavior; public usage example if API changes; and benchmark coverage only when the change affects a measured hot path or retention. Avoid writing shallow tests that merely restate a trivial implementation.

The first implementation task completed the M0–M1 harness. The current M2 slice adds the standalone `httpkit-core` library, 14 deterministic core cases, four constructor properties, installed bytecode/native consumers and compile-fail fixtures, executable odoc examples, a native core fuzz target, and initial allocation/time microbenchmarks. `tools/harness readiness --milestone M2` requires matching evidence from OCaml 5.5.0 and AFL smoke. This slice validates lexical construction, not wire serialization; the M3 codec will validate message combinations before serialization. No parser, listener, engine, or runtime adapter is present yet.

## 21. Release acceptance and honest limits

Before recommending the initial implementation for internet-facing use, require all of the following:

- Every first-release capability implemented, every applicable contract case executed, and no unresolved high-impact framing/ownership/cancellation defect.
- Full deterministic, property, runtime, install/API, and intermediary suites passing on the declared platform/compiler matrix.
- Curated mutations detected; coverage exclusions reviewed; reference disagreements classified with evidence.
- Fuzz campaigns complete at the documented budgets with no untriaged crash, hang, resource-limit breach, or semantic finding. A fix reruns all seeds and at least the affected target's release campaign; an engine-wide change reruns all engine-dependent targets.
- Bounded-memory and progress checks passing, stable performance baseline available, and regressions either fixed or explicitly accepted with measured rationale.
- API review complete; streaming, errors, body ownership, limits, timeouts, and raw-target semantics documented with executable examples.
- Independent security review of framing, lifecycle, and adapters; a documented private vulnerability contact and patch/release process.

No finite corpus, test count, fuzzer runtime, coverage score, or benchmark proves absence of vulnerabilities. This harness covers the declared HTTP/1.1 behavior and tested integrations. It does not validate application authentication, routing normalization, TLS cryptography, or unimplemented protocols.

Future packages must inherit the same structure: a standalone public consumer, threat/limit contract, deterministic model or fixtures, fuzz targets where useful, and performance evidence. Their addition must not weaken the core's existing invariants.

## 22. Worked scenario and minimum invariant catalog

The following is the intended shape of a typed scenario, expressed as a readable transcript rather than production OCaml API syntax:

```text
case BODY.CANCEL.BACKPRESSURE
profile: incoming_queue=8, outgoing_queue=8, adapter_staging=4
role: server
1. Offer a valid POST header block declaring a 16-byte body.
2. Deliver the headers event to the application script.
3. Pause application body consumption.
4. Offer body bytes repeatedly, honoring each accepted-prefix count.
5. Assert incoming queue <= 8 and staging <= 4; remaining bytes stay with peer.
6. Ask the application to begin a small response.
7. Permit output writes of 1 byte, then 2 bytes, then withhold readiness.
8. Cancel the connection through the runtime-specific mechanism.
9. Run enabled cleanup actions to quiescence under the operation watchdog.
10. Assert exactly one terminal outcome; no successful request-body completion;
    no remaining owned flow, timer, body waiter, or buffer lease.
11. Make output readiness available again.
12. Assert no second completion and no resumed write on the closed flow.
```

Run this against the pure fake scheduler to test the scenario/model, then each adapter with controlled transport readiness, then a bounded real-socket counterpart. The pure engine version receives an explicit abort command; it does not pretend to implement runtime cancellation itself. Permuting steps 7 and 8 exercises the race while preserving prerequisites.

Minimum invariant IDs that must exist before engines are marked complete:

| ID | Invariant |
| --- | --- |
| INPUT.PREFIX | Accepted input is a prefix within the offered slice |
| INPUT.FRAGMENT | Valid message meaning/boundaries are invariant under input fragmentation |
| INPUT.EOF | EOF is distinct from empty input and temporary blocking |
| OUTPUT.PREFIX | Acknowledged output is a prefix within the offered bytes |
| OUTPUT.EXACT | Combined acknowledged output has no missing, duplicate, or reordered bytes |
| OUTPUT.LIFETIME | Pending output remains valid until its documented release point |
| COMMAND.ONCE | A command is either accepted once, backpressured without acceptance, or rejected |
| MESSAGE.ORDER | Message and response ordering follows the supported connection policy |
| MESSAGE.TERMINAL | Completion, failure, and handoff have mutually consistent terminal behavior |
| MESSAGE.ISOLATION | Data/metadata never cross message or connection identity boundaries |
| FRAME.UNIQUE | Every accepted message has a unique documented framing decision |
| FRAME.NO_REUSE | A framing failure or unread abandoned body cannot become a fresh request |
| BODY.DEMAND | Consumption controls capacity without silently buffering the full body |
| BODY.LIMIT | Accounted retained bytes respect all configured component limits |
| BODY.TRAILERS | Trailers remain distinct from data and precede terminal completion |
| ERROR.COMMIT | Failure after response commitment cannot create another HTTP response |
| ERROR.BOUNDED | Error diagnostics cannot amplify input without a bound or inject control output |
| HANDOFF.ONCE | Flow plus residual bytes transfer once after required output is flushed |
| CLOSE.PROGRESS | Graceful/forced close reaches a valid terminal state under its stated assumptions |
| CANCEL.WAKE | Cancellation terminates/wakes owned pending operations without later duplicate success |
| TIME.ABSOLUTE | Header completion deadline is not indefinitely extended by partial progress |
| WORK.PROGRESS | Runnable work consumes input, emits output/event, changes state, or explicitly blocks |
| RESOURCE.CLEANUP | Terminal cleanup releases owned transports, tasks, timers, and leases |
| API.INDEPENDENCE | A public primitive can be used with only its declared dependencies |

Each ID maps to at least one positive control and one counterexample or deliberately faulty subject. This catalog is extended as capabilities arrive; deleting an invariant requires an explicit contract change and review.

## M3 implementation update

`httpkit-http1` supplies incremental head/body decoding and encoding with strict framing, target/Host checks, bounded work and metadata, chunk extensions, trailers, and EOF handling. The public suite, installed consumer, independent response reference, fragmentation fuzz targets, and geometric head benchmarks run in compiler validation. See [HTTP/1 policy](http1.md). Engine sequencing, adapter behavior, broad interop, long fuzz campaigns and independent security review remain later gates.

## M4 implementation update

The standalone engine implements both roles with one-event input backpressure, bounded output reservations, exactly-once accepted commands, serial pipeline admission, early-response close/discard, informational/Expect handling, cancellation, shutdown and negotiated handoff. Generated output-prefix/client models, multi-domain isolation, installed consumers and native AFL targets exercise it. [Engine details](engine.md). Runtime cleanup and clock behavior remain M5 work.

## M5 implementation update

Both native adapters, pure deadline policy, bounded admission/collection, mock
lifecycle schedules, real socket streaming and separate installed-consumer tests
are implemented. See [adapter contracts and measured test scope](adapters.md).
Milestone evidence requires OCaml 5.5.0, docs, installed runtime isolation and
source-matched fuzz smoke. Broader release campaigns remain separate gates.

## M6–M7 implementation update

M6 provides the [direct/Nginx interop and streaming evidence](interop-performance.md).
M7 adds [executable release assessment](release.md), a separate coverage lock,
curated source mutations, nine selectable local fuzz targets and retained campaign
artifacts. Capability implementation and release approval remain separate: full
release readiness stays false until every required source-matched gate completes.
The original broad differential, long-soak and independent-review requirements
remain in force; the new smoke lanes do not silently replace them.
