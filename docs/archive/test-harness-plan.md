# Original harness design criteria

Historical design from September 9–10, 2026. This is a record of proposed
review criteria, not a claim that each experiment is implemented or passed.
Current commands are in [testing](../testing.md); the version-2
[release policy](../release.md) supersedes the old AFL, CI and campaign schedules.
The full original plan is available in Git history at `49246bd`.

## Threat model

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

## Scenario design

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

## Performance review criteria

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

## Coverage and review criteria

Maintain three separate coverage reports:

1. Contract coverage: every supported requirement has positive/negative/boundary evidence where meaningful.
2. State coverage: valid transitions, terminal paths, and invalid commands exercised.
3. Instrumentation coverage: Bisect expression points reached by tests.

Do not label expression coverage as branch coverage, and do not claim 100% coverage proves correctness. Initially require 100% mapped required contract entries and documented coverage of every supported lifecycle transition. At release, target at least 95% instrumented points in first-party core/codec/engine code, with reviewed justifications for exclusions; adapter paths are assessed by transition/fault coverage as well as point coverage.

Maintain a targeted mutation set: remove a framing rejection, permit one excess buffered byte, fail to decrement retained-byte accounting, omit a cancellation wakeup, duplicate completion, and accept stale IDs. Apply mutations in isolated disposable copies during dedicated jobs, never to the working checkout. Every curated mutation must be killed by a named test. This is a gate for known protections, not a claim of exhaustive mutation coverage.

Require a second reviewer for framing, buffer ownership, cancellation, and limit changes before an internet-facing release. The reviewer checks oracle independence and whether the test fails on the prior/broken behavior. Automated or AI review can supplement this; external security review remains separate evidence.

Any reused parser/engine code gets an upstream provenance record and a maintained review queue for upstream security fixes. Dependency checks report updates and advisories; they do not automatically update the implementation or corpus.

## Worked scenario and invariant catalog

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
