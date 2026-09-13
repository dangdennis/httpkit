# Code quality consolidation plan

Status: implemented; validation is tracked by source-matched local evidence. Created 2026-09-11 from the
three-agent code review and focused reproduction probes.

The objective is to make httpkit easier to read, compose and audit while fixing
the concrete contract and evidence defects found in the review. Preserve the
pure core → HTTP/1 codec → engine → native adapter architecture, the small router,
and the Transition middleware style. Work through the commits below in order;
do not mix protocol fixes with broad representation changes.

This plan complements the [benchmark backlog](benchmark-todos.md) and
[test harness plan](test-harness-plan.md). Completing it does not close the
independent review, long campaign, soak or platform gates in the
[M7 checklist](m7-manual-checklist.md).

## Execution record

C1–C12 code and documentation changes are implemented. The checklist below
retains the original review criteria; use `_artifacts/` reports for actual
validation outcomes, source hashes and remaining release gates.

- Operational requirements are explicit, including non-removable negative
  controls and named release inventories. Dense release/mutation/campaign code
  is formatted and central release predicates have names.
- Expect finalization and both native upload examples are corrected. Trailer
  membership uses a balanced set with honest complexity documentation.
- Adapter tests assert exception propagation, cleanup precedence and precise
  read failures. Both convenience APIs expose immutable engine settings and
  structured failure text. Native/bytecode consumer fixtures exercise the API.
- Pipeline identity uses ordinal targets and matching response headers. This
  intentionally works even for empty-body lanes; payload sizes continue to vary
  across the existing matrix instead of changing within each pipeline.
- Body/exchange configurations and input windows are shared and named. Their
  large payloads are lazy; listing does not execute protocol preflight. Other
  small family catalogs can still construct their pure tables during listing.
  Full lazy construction of every small table was not needed to fix the
  expensive body/exchange behavior or preflight leakage.
- Sample budgets account for selected cases and calibration. Workload hashing
  includes extracted benchmark modules. Raw retained comparisons and exclusions
  are recomputed/checked before reports are accepted.
- Engine RX/TX states are explicit, and test/requirement catalogs have named
  groups. Production router behavior and Transition signatures are unchanged.
- The optional single-character chunk predicate optimization is deferred: it
  is separate from the confirmed trailer complexity fix and needs its own
  measured justification. No API was added solely for this micro-optimization.

The geometric token-membership fixtures are now available in the parser
benchmark family. Benchmark timings remain advisory; new pipeline workloads
cannot be ranked against historical identical-message pipeline reports.

## Constraints and working rules

- OCaml 5.5.0 only. Preserve mise → opam → Dune and the normal/coverage Dune
  locks. No dependency refresh is required for this work.
- Prefer additive public API changes and private representation improvements.
  Preserve defaults, ownership, raw target handling and route declaration order.
- Keep Eio and Lwt cancellation machinery separate. Share concepts, fixtures and
  parity requirements; do not introduce a generic runtime functor.
- Keep benchmark-only router indexes out of production.
- The original language constraint is superseded by the approved OCaml tooling
  migration. Operational checks remain explicit and non-removable.
- Add regression tests that fail for the identified defect. Refactors need
  behavioral equivalence checks, not tests that merely mirror the new structure.
- Each implementation commit includes its relevant comments and documentation,
  passes its focused checks, and is committed/pushed as a separate milestone.
  Record local validation and CI status separately. A blocked CI run is not a pass.
- Retain existing evidence unchanged. Source/workload hashes must describe the
  code actually measured; never relabel old measurements after a change.

## Delivery sequence

| Commit | Deliverable | Dependency / exit gate |
| --- | --- | --- |
| C1 | Explicit operational evidence checks | Debug and release tooling reject false success |
| C2 | Consistent Expect write gating | Engine regression proves no premature final chunk |
| C3 | Expect policy in both native examples | Client receives interim/final head before sending body |
| C4 | Bounded trailer membership work | Semantic equivalence and documented complexity |
| C5 | Strong adapter exception/error tests | Swallowing or misclassifying errors fails tests |
| C6 | Complete retained-report validation | Altered summaries/exclusions are rejected |
| C7 | Distinguishable pipeline messages | Reorder and duplicate/omission controls fail |
| C8 | Named benchmark configuration and diagnostics | Case selection, fixtures and measurement boundaries preserved |
| C9 | Selection-aware benchmark setup and time budgets | Selected work alone is prepared; budget matches configuration |
| C10 | Explicit engine transition helpers/state | C2 and existing lifecycle traces remain equivalent |
| C11 | Adapter configuration, diagnostics and Transition examples | Installed consumers and runtime parity pass |
| C12 | Catalog/documentation cleanup and final validation | Traceable findings closed and fresh evidence recorded |

C1–C7 fix behavior or evidence before structural work. C8 precedes C9 so case
selection has a clear catalog to operate on. C10 follows the engine regression
work. Do not merge these into one large cleanup commit.

## C1 — Make operational evidence checks unconditional

Primary files: `tools/devlib/mutations.ml`, `tools/devlib/fuzz.ml`, `tools/devlib/evidence.ml`,
`tools/devlib/release.ml` and their tests. Audit `coverage.ml`, `performance.ml`,
`interop.ml`, bootstrap/package tooling and consumer checks for the same pattern.

The confirmed defect is that optimization removes the mutation-result assertion
and allows a successful mutant execution to be recorded as `KILLED`. Campaign
assertions similarly guard data later recorded as successful evidence. This is
not a finding that past ordinary runs were false.

- [ ] Inventory operational assertions: subprocess outcomes, source stability,
  mutant site identity, execution budgets and finding counts.
- [ ] Replace these with explicit exceptions, using a small shared requirement
  helper where it improves consistency. Do not rely on clearing an environment
  variable as the only protection.
- [ ] Write evidence only after every applicable check succeeds. Failed runs
  must not leave a newly written PASS artifact; preserve logs for diagnosis.
- [ ] Derive reported counters from validated observations rather than masking
  unexpected observations with hardcoded successful values.
- [ ] Extract narrow result-validation functions where needed to test them
  without launching a full AFL campaign or mutation build.
- [ ] Test a surviving mutant, compilation failure, failing baseline, site drift,
  changed source hash, insufficient campaign duration/executions and findings.
  Run validator controls against the OCaml developer CLI in debug and release
  builds, including a build with assertions disabled. The tests themselves must not use removable assertions.
- [ ] Expand dense release checks into named validators. Require the declared
  interop lanes and curated mutant identities, reject duplicate/missing entries,
  and update producers and positive fixtures together. Use inventories from the
  actual harness, not new arbitrary counts or test fixtures containing `[{}]`.

Acceptance: every negative fixture fails in all validated build modes; valid evidence
still passes; release validation reports the failed condition clearly. This is
consistency validation, not a cryptographic authenticity guarantee for artifacts.

## C2 — Enforce Expect gating consistently in the engine

Files: `lib/engine/httpkit_engine.ml`, its interface, `test/engine/engine_cases.ml`
and `docs/engine.md`.

- [ ] Centralize the applicable send permission check used by `send_data` and
  `finish`. Preserve invalid-command checks and server response behavior.
- [ ] Make pending client Expect requests backpressure body commands, including
  finalization, until `100 Continue` or the explicit continuation override.
  Use this consistent rule for zero-length bodies too; document the choice.
- [ ] Prove rejection/backpressure does not mutate codec writer state, queue
  bytes, mark transmission done or consume supplied trailers.
- [ ] Cover fixed/chunked empty and nonempty requests, trailers, intervening
  informational responses, explicit override and an early final response.
  An early final response must not accidentally grant upload permission.
- [ ] Verify the emitted bytes after permission is granted, completion exactly
  once, and existing connection-reuse rules.

Acceptance: the reproduced premature `0\r\n\r\n` is impossible before permission;
the existing engine boundary and scenario suites pass.

## C3 — Teach a complete Expect policy in the routing examples

Files: `examples/routing/eio_server.ml`, `examples/routing/lwt_server.ml`, their
shared application module, `tools/devlib/interop.ml`, `docs/examples.md`.

- [ ] Decide on the request head before collecting a body: for a supported
  upload that will be consumed, emit 100; for a rejected request, send the final
  response and follow the engine's discard/close policy.
- [ ] Share a small pure policy decision if both examples need the same logic;
  leave native I/O sequencing explicit in each example.
- [ ] Add bounded integration tests that send only the head and require a
  response before sending the body. Test both native examples and an ordinary
  upload as a positive control.
- [ ] Cover early rejection without waiting for the upload, and unsupported
  expectations according to the codec's existing policy.
- [ ] Explain why the policy precedes body collection and how completion affects
  keep-alive reuse. Ensure tests terminate their server processes on failures.

Acceptance: both examples support an actual waiting Expect client; no test relies
on a client sending the body unconditionally to make progress.

## C4 — Remove repeated trailer membership scans

Files: `lib/http1/httpkit_http1.ml`, `.mli`, `test/http1/http1_cases.ml`,
`docs/http1.md`, and focused parser benchmark fixtures.

- [ ] Build an internal membership index once for Connection tokens and use it
  when validating declared trailer names. Preserve externally visible lists,
  duplicate handling and all existing rejection rules.
- [ ] Prefer a deterministic balanced set for a simple worst-case bound. Do not
  use an unqualified hash-table average to claim worst-case linear work.
- [ ] Separate the documented linear byte scan from semantic membership work.
  State the actual bound, including name comparison costs; remove the current
  unconditional linear-work promise unless the implementation proves it.
- [ ] Test duplicate token lists, a matching token near the end, disjoint lists,
  forbidden names and existing header-byte/count boundaries.
- [ ] Add geometrically increasing token-count fixtures through the public
  decoder, including the accepted approximately 12 KB / 3,000-by-3,000 case.
  Use deterministic correctness checks in CI and advisory time/allocation
  measurements to confirm the repeated cross-product scan has gone away.
- [ ] Inspect the per-character chunk token check that constructs validated
  one-character names. If simplified, use a private grammar predicate with
  exhaustive byte-class equivalence tests; do not expand the public core API.
  Keep this optional optimization in a separate commit if it obscures the fix.

Acceptance: accepted/rejected semantics are unchanged, membership no longer scans
the full Connection list for every Trailer token, and complexity docs are honest.

## C5 — Make adapter tests prove their named guarantees

Files: `test/adapter/eio_test.ml`, `lwt_test.ml`, `adapter_fixtures.ml`.

- [ ] Make normal return fail the handler-exception test; assert the original
  exception is propagated and cleanup occurs once.
- [ ] Exercise a handler failure combined with a close failure, asserting the
  documented primary-error precedence in both runtimes.
- [ ] Replace numeric read-failure modes with named fixtures and expected error
  categories. Assert transport failure, invalid transport count and premature
  EOF produce their documented classifications rather than any adapter error.
- [ ] Keep tests bounded so timeout cannot masquerade as the expected failure.
- [ ] Remove the unreachable shutdown branch and abandoned setup in the Eio
  idle-deadline test; keep the real shutdown test explicit.
- [ ] Preserve native start barriers, cancellation checks, controlled clocks,
  active-operation counters and independent expected wire bytes.

Acceptance: a deliberately swallowed exception or wrong failure category causes
the relevant test to fail; both native suites remain deterministic.

## C6 — Validate every retained benchmark report layer

Files: `tools/devlib/benchmarks.ml`, `tools/devlib/benchmark_test.ml`, `docs/benchmarks.md`.

- [ ] Introduce one validation path used before rendering a fresh report and
  before comparing either retained report.
- [ ] Validate catalog uniqueness, sample inventory, compiler/config/seeds,
  finite metrics, calibrated counts and sample count as today.
- [ ] Require sample exclusions to agree with report exclusions and validate
  complete comparison groups, implementation identities and exclusions together.
- [ ] Recompute aggregate results and library comparisons, including time and
  allocation ratios, from raw samples. Reject inconsistent derived fields.
- [ ] Define schema handling explicitly. Preserve old reports as historical
  files; reject unsupported/incomplete schemas with a useful message rather than
  silently filling missing evidence or rewriting source artifacts.
- [ ] Add focused fixtures for altered ratios, allocation summaries, sample
  exclusions, duplicate implementations, missing groups and a valid round trip.
- [ ] Audit the retained latest report with the new validator. Record any
  limitations separately; an integrity gap does not prove the report was altered.

Acceptance: the review's in-memory altered-report probe is rejected, valid
reports render and compare, and diagnostics name the inconsistent section.

## C7 — Give every pipeline message an identity

Files: `bench/suite_exchange.ml`, relevant shared fixtures, benchmark docs.

- [ ] Give each request and expected response an ordinal identity in the target,
  a header or payload, and use varied body lengths where the lane supports it.
- [ ] Assert request/response association, order, exact bytes, message count,
  completion and suffix preservation independently of the implementation.
- [ ] Add negative oracle controls for reordered messages, duplicate plus
  omission, truncation and an extra response. A single-message oracle cannot
  establish pipeline correspondence.
- [ ] Keep partial acknowledgements, paused readers and fragmentation checks.
- [ ] Treat changed payloads/oracle work as a changed benchmark workload. Retain
  old reports but do not claim an old/new speedup across incompatible workloads.

Acceptance: all negative controls fail for the intended reason and all supported
libraries pass the new common workload or receive an explicit group exclusion.

## C8 — Make benchmark code read like the experiment it runs

Files: `bench/suite_external_body.ml`, `suite_exchange.ml`, `suite_support.ml`,
and a small shared fixture/driver module only where justified.

- [ ] Replace positional boolean tuples with records and named variants for
  request/response direction, consumption (`Owned_scan`, `Borrowed_scan`,
  `Collect`), transport fragmentation and immediate/deferred scheduling.
  Unsupported combinations must be impossible or rejected during preparation.
- [ ] Replace long positional runner argument lists with a named configuration.
- [ ] Represent comparison metadata as one optional record containing group and
  implementation, instead of two independently optional strings.
- [ ] Move shared fixture construction out of the body experiment module so
  exchange tests do not depend on an unrelated experiment's implementation.
- [ ] Extract only duplicated input-window bookkeeping: available suffix,
  advancement, need-more state and readiness. Keep ownership adaptation and
  library-specific connection calls visible.
- [ ] Introduce named invariant diagnostics with case/operation, expected/actual
  values, byte offsets and underlying formatted errors. Build diagnostic strings
  on failure; capture context/backtraces at the job boundary.
- [ ] Preserve fixture construction outside timing, per-operation correctness
  checks inside timing, owned/borrowed distinctions and explicit exclusions.

Acceptance: a reader can understand a case at its declaration without consulting
tuple destructuring. Catalog IDs, fixtures, exclusions and untimed correctness
results match before/after this refactor. Review allocation changes with a focused
sample; workload hashes may change with harness source, so do not bypass existing
compatibility checks just to obtain an automated ratio.

## C9 — Align selection, preparation and execution budgets

Files: `bench/suite_bench.ml`, `suite_support.ml`, `tools/devlib/benchmarks.ml` and tests.

- [ ] Enumerate lightweight case descriptions, filter selections while retaining
  complete comparison groups, then prepare/preflight only selected work.
- [ ] Make listing independent of fixture execution. Represent known exclusions
  as catalog data and discovered exclusions as explicit preparation results;
  remove reliance on mutable global accumulation where feasible.
- [ ] Compute a sample budget from selected case count, target duration, bounded
  calibration attempts, warmup and setup allowance. Keep a documented hard cap
  and reject incompatible configurations before running.
- [ ] Report the selected count and estimated budget. Emit progress outside
  retained timing. Preserve partial logs on timeout without producing PASS data.
- [ ] Test budget arithmetic and early rejection with fake clocks/processes;
  do not require a multi-minute timing test to verify timeout calculations.
- [ ] Test that an unselected failing preparation does not break a focused run,
  incomplete external groups are rejected, and selection order is deterministic.

Acceptance: the allowed 1,000 ms setting cannot silently collide with a fixed
600-second full-suite timeout. Small selections do not execute unrelated work.

## C10 — Make engine lifecycle invariants local

Files: `lib/engine/httpkit_engine.ml`, `test/engine/engine_cases.ml`,
`engine_scenarios.ml`, `docs/engine.md`.

- [ ] Write a transition table for receive progress, send progress, continuation
  permission, early final response, discard, completion and handoff. Identify
  which states are independent and which flag combinations are invalid.
- [ ] Replace ambiguous option/boolean combinations with small private RX/TX
  variants where this removes invalid states; otherwise use named transition
  helpers that update related fields together.
- [ ] Give `incoming = None` meanings explicit names. Preserve distinct incoming
  completion and outgoing drain semantics; neither implies the other.
- [ ] Name compound policy predicates, including the chained upgrade boolean
  comparison, so the expression reads as a protocol decision.
- [ ] Route state changes through the helpers; add comments explaining invariants
  and ownership, not comments that restate assignments.
- [ ] Compare observable event/output/error traces for existing scenarios before
  and after, including fragmented input, early finals, backpressure, discard,
  partial writes, connection reuse, stale IDs and tunnel suffixes.

Acceptance: no public API or intended behavior changes in this commit. A reviewer
can locate the invariant for a command without reconstructing every constructor.
If this cannot be achieved in one small diff, split RX and TX changes and validate
each; do not replace the engine wholesale.

## C11 — Complete adapter configuration and diagnostics

Files: both native adapter `.ml`/`.mli` files, installed consumer fixtures,
`examples/routing/`, and adapter/middleware/example guides.

- [ ] Let `serve_connections` receive immutable engine configuration, mirroring
  the existing server constructor's limits through optional labeled arguments
  where practical. Keep all defaults. Construct a fresh engine per connection;
  never accept one engine instance for reuse across connections.
- [ ] Check invalid configuration at a clear boundary and test two connections
  receive the requested limits without sharing lifecycle state.
- [ ] Add matching failure formatters in Eio and Lwt. Preserve failure categories
  and meaningful transport exception detail without including request/body data.
  Update examples to use them instead of opaque `Error(_)` output.
- [ ] Mirror essential operation docs: continuation override, discard followed by
  incoming Complete before reuse, Complete not meaning output drained, handoff
  restrictions and shutdown behavior.
- [ ] Add a small executable Transition example with public/protected routes and
  an asynchronous decision in each runtime. Keep authentication illustrative;
  do not introduce a production authentication subsystem.
- [ ] Replace unexplained capture `Option.get` calls in examples with a named
  helper that reports the broken route/capture invariant. Do not add a new typed
  routing API merely to remove an example assertion.
- [ ] Compile native and bytecode installed consumers and retain middleware
  negative compilation tests proving invalid context transitions fail.

Acceptance: an application can tune bounds without rebuilding the admission
helper; corresponding Eio/Lwt calls have matching configuration and documentation;
the Transition example demonstrates composition without custom framework glue.

## C12 — Finish catalogs, documentation and evidence

- [ ] Group engine cases and requirement registry entries by named concerns,
  then assemble one final catalog. Preserve IDs, ordering where meaningful and
  requirement coverage. Avoid a new test DSL.
- [ ] Correct engine accounting docs: pending input Data payload and queued
  serialized output bytes are different quantities. Remove future-tense native
  adapter descriptions now that adapters exist.
- [ ] Update README, design, engine, adapter, example and benchmark guides to
  describe final behavior; link the new regression coverage where useful.
- [ ] Update the benchmark backlog without conflating implemented fixtures,
  measured results and release approval. List remaining review findings explicitly.
- [ ] Run final fast/consumer/docs validation, relevant fuzz smoke for changed
  codec/engine/adapter paths, and fresh focused body/exchange/parser benchmarks.
  Run the full benchmark smoke once; reserve long calibrated runs for a suitable
  machine and configured budget. Preserve advisory/noisy labels.
- [ ] Record source revision, toolchain, commands, results and any unavailable CI
  or external gates. Do not reuse stale PASS evidence for the new revision.
- [ ] Review the final diff specifically for naming, local invariants, error
  messages, public defaults and unnecessary abstractions. Check every C1–C11
  acceptance criterion rather than using a test count as completion evidence.

## Validation commands and scope

Use the existing wrappers and locked compiler. Representative focused commands:

```sh
tools/dev bench-test
tools/dev selftest release
tools/dune-pkg runtest test/engine test/http1 test/adapter
tools/dev routing-test
tools/dev consumer protocol
tools/dev consumer adapter
tools/dev consumer middleware
tools/dune-pkg build @doc
tools/harness run --tier fast
tools/dev bench --external --family exchange --quick
tools/dev bench --external --family body --quick
```

Add C1's optimization-mode tests to the normal tooling test entrypoint when they
are implemented. Run other consumer/package checks when their boundary changes.
Use deterministic negative controls for report and protocol correctness; wall-clock
performance thresholds are advisory until stable reviewed budgets exist.

## Definition of done

All commits have their focused checks and relevant documentation; known protocol
and evidence defects have regression coverage; benchmark selection/configuration
is readable and bounded; engine state invariants are local; adapter APIs preserve
defaults and expose useful configuration/errors. Fresh validation is tied to the
final source revision. Remaining long-running and independent M7 gates are
reported as outstanding, not inferred from this consolidation work.
