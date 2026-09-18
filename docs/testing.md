# Testing and evidence

Use the pinned toolchain from [development](development.md). Run one Dune process
per build directory. Finish code, docs, tools and lock changes before measuring a
candidate: all contribute to its fingerprint.

## Start with the changed boundary

| Change | Focused checks |
| --- | --- |
| Core values, codec or engine | `tools/dune-pkg runtest test/core test/http1 test/engine` |
| Runtime ownership or cancellation | `tools/dune-pkg runtest test/adapter test/production` |
| Application helpers and handlers | `tools/dev framework-test` |
| Database behavior | `tools/dev databases` |
| Authentication and sessions | `tools/dune-pkg runtest test/extensions` |
| Outbound clients | `tools/client-check _artifacts/client-feedback/new-run` |
| Benchmark/reporting tools | `tools/dev bench-test` and `tools/dev selftest` |
| Final integration | `tools/dev validate` |

`validate` builds libraries, examples and API docs; runs regression/property,
tooling and integration checks; and builds separate installed-package consumers.
It does not run every long campaign or certify every backend/mode combination.
In particular, PostgreSQL bytecode is currently blocked by a
[recorded binding crash](status.md#what-we-found), despite other bytecode passes.

Database checks start and stop their own PostgreSQL instance and exercise SQLite.
Set `FRAMEWORK_PG_BIN` to an existing PostgreSQL binary directory if needed.
They require native database libraries and local process/socket access.

## Security and correctness

A regression needs an independent expected result and a control that detects the
broken behavior. Parser tests cover strict framing, segmented input, exact limits,
EOF and terminal failure. Lifecycle tests track ownership through cancellation,
backpressure and shutdown. Installed consumers check package isolation and public
APIs; compile-fail fixtures need a passing counterpart.

For deeper checks, use [native generated-input campaigns](native-fuzz.md),
[interop](interop-performance.md), coverage and curated mutations:

```sh
tools/dev coverage core
tools/dev coverage framework
tools/dev coverage extensions
tools/dev mutations
tools/dev mutations framework
```

Coverage measures instrumented points, not security or branch coverage. A mutant
must compile and fail a real test; a build failure or timeout is not a kill.
The [synthetic harness](harness-contract.md) tests its own oracle separately from
real protocol implementations. AFL execution remains deferred.

## Performance and resource checks

Use [benchmarks](benchmarks.md) for primitive costs and equivalent-library
comparisons; use [load testing](load-testing.md) for HTTP endpoint, capacity,
slow-client and blocked-output checks. Client changes have their own combined
correctness/resource/measurement loop in [the client guide](client.md#feedback-loop-and-evidence).

Keep CPU-heavy campaigns separate from timing measurements. Distinguish allocated
bytes, retained heap, queued payload, descriptors and process RSS. Test exact
resource bounds deterministically; timings on shared hosts remain advisory.
The [profiling hang](profiling-hang.md) requires an external watchdog during
further diagnostic runs. A passing retry does not resolve a failed attempt.

Long application validation is explicit:

```sh
tools/dev framework-validate --long
```

This runs its baseline checks before profiles, a 30-minute SQLite canary and a
two-hour PostgreSQL soak. Preserve failures and terminal exit status; a report left
`RUNNING` by a killed process is not success. See [local platforms](local-validation.md)
for Linux validation and [release policy](release.md) for required inventories,
budgets and independent reviews.

## Evidence rules

Keep the command, source/binary/lock hashes, platform, logs and original findings
with each report under `_artifacts`. Never relabel an older report for new sources
or erase a timeout because another run passed. Smoke, sustained load, independent
review and deployment acceptance answer different questions.

Hosted CI and AFL are excluded from the current workflow. The release assessor
uses the declared local-platform/native-campaign replacements. A successful push,
coverage percentage or finite test campaign is not production approval.
