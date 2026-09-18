# Beta and production release evidence

For current results, read [validation status](status.md). For private application
setup, use [the internal-use guide](internal-use.md). This document defines the
release assessor; its gates are unchanged by internal adoption work.

The approved [beta delivery plan](beta-plan.md) covers all existing application
features with WebSockets explicitly experimental. Public beta publication is a
separate owner-approved step after the beta evidence passes. Neither a successful
push nor a passing short test run authorizes publication or a production claim.

## Assess a frozen candidate

```sh
tools/dev release --profile beta --output _artifacts/beta-release.json
tools/dev release --profile production --output _artifacts/production-release.json
```

Omitting `--profile` selects production. The JSON schema is version 2. Success is
`BETA_READY` or `PRODUCTION_READY`, with exit 0; missing, stale or failed required
evidence is `NOT_READY`, with exit 3. Unknown profiles are usage errors. Harness
`readiness --release` and `readiness --milestone M7` continue to use production.
Consumers of the old `READY` result must migrate to the explicit profile result.

Both profiles require local Linux x86_64 and macOS arm64 validation on OCaml 5.5.0,
all installed native/bytecode consumers, six direct/Nginx interop lanes, all seven
curated mutants, measured coverage, all fourteen native fuzz targets, feature
review, stress/soak, deployment, dependency and packaging evidence. Production
additionally requires independent security and API reviews. Their absence remains
visible as non-required `PENDING` gates in beta. WebSocket stays experimental in
both profiles; passing these gates does not upgrade its support status.

Policy v2 uses reproducible local Linux/macOS evidence and native generated-input
campaigns. Hosted CI and AFL are excluded from the current workflow; neither is
recorded as passed. Restoring either is separate work.

## Native campaign and coverage requirements

Each target requires at least 1,800 seconds of completed child execution, 100,000
checked inputs and 20 distinct nonnegative 64-bit seeds. Seed spelling is
normalized before counting. Every batch must exit successfully, record its binary
identity and checked/skipped/generated counts, and satisfy their accounting.
Timeouts, skipped-only batches, reused seeds, incomplete regression replay and
unresolved findings cannot qualify. Source and binary identity must remain frozen.
The native runner records checked-input accounting and supports resumable
duration campaigns. Earlier long campaigns completed; a new candidate still
needs evidence matching its own source and binaries.
Smoke reports do not satisfy the duration requirement.

Coverage minima are 95% core/codec/engine, 85% framework and 80% extensions. Reports
must retain visited/total points, a consistent computed percentage, missing-file
inventory and critical-path review. These are instrumented points, not branch
coverage or security percentages. Additional per-file controls and upstream
libraries are not erased by exceeding an aggregate threshold. Existing Bisect
instrumentation remains development-only, on the separate coverage lock.

`tools/dev coverage core|framework|extensions` produces per-file summaries,
HTML and line reports. Framework and extension measurements include the shared
production lifecycle/observation suite; extensions also run the bounded password
worker example. These are real tests of the selected libraries, not additional
excluded code. Module aliases and the type-only `lib/web/observation.ml` have no
executable points and are listed explicitly in their applicable exclusions.
The parser accepts the pinned reporter's spacing around `%`; missing required
files still fail measurement. A completed measurement below its threshold is
not a passing release gate, and HTML coverage does not replace critical-path review.

Curated mutations must compile and fail real regression tests. Compilation errors
and timeouts are not kills. Three lower-layer and four framework mutations are
required; these are selected test controls, not an exhaustive mutation score.

## Evidence manifest contract

The assessor reads `_artifacts/release-manifest.json`, rather than accepting loose
historical PASS files. Its fields are:

- `schema_version`: 2; `compiler`: `5.5.0`.
- `candidate_commit`: the full candidate Git commit; `source_sha256`: the current
  `tools/dev fingerprint` value; `lock_sha256`: `Release.lock_hash ()`, covering
  sorted repository-relative paths and bytes of both lock directories.
- `reports`: uniquely named entries containing `name`, relative `path`, `sha256`,
  `platform`, nonempty `command` argument list, and nonempty `attachments`.
- Each attachment has a relative `path` and content `sha256`. Attach original
  logs/measurements/review records, not placeholder approvals.

Every referenced JSON report must contain `status: PASS` and the matching
`source_sha256`, plus its gate-specific fields. Duplicate JSON keys, duplicate
report names, altered/missing attachments, absolute or parent paths, symlink
escapes, nonregular files and files exceeding 16 MiB are rejected. Split large
logs into bounded attachments. Hashes bind local evidence against accidental
substitution; they are not signatures or proof that a report author is honest.
The evidence directory must remain stable during assessment.

Required report names and payload contracts:

| Name | Required payload beyond status/source |
| --- | --- |
| `compiler/<platform>` | `compiler`, matching `platform`, `execution: LOCAL`, installed-consumer/integration booleans |
| `interop` | Exact six-lane `results` inventory |
| `mutations`, `framework-mutations` | Exact curated `results`: `name`, `compiled: true`, `status: KILLED` |
| `coverage/core`, `/framework`, `/extensions` | `visited`, `total`, `percent`, `missing_files: []`, `critical_paths_reviewed: true`, `metric: instrumented points, not branches` |
| `native/<target>` | `target`, `mode: NATIVE`, `runs` with seed/status/exit/seconds/checked/skipped/generated/failed/binary_sha256 and `timing_scope: child_campaign`; each batch has checked inputs and zero failures; `regression_inventory_replayed`, `negative_controls_passed`, empty `unresolved_findings` |
| `internal-review`, `reference-differential`, `proxy-observers`, `stable-performance`, `soak`, `contract-coverage`, `dependencies`, `packaging` | `reviewed_by`, `acceptance_passed: true`, empty `unresolved_findings`, with substantive supporting attachments |
| `support-scope` | Exact `features` inventory with `BETA_TESTED` status, `websocket: EXPERIMENTAL`, `public_production_claim: false` |
| `security-review`, `api-review` | `reviewer`, `approved: true`, `independent_of_implementation: true`, `identity_verified_by`, empty `unresolved_findings`; owner-verified independent review attachments |
| `private-reporting` | `verified_channel`, `verified_by`, verification evidence |

The exact feature and target inventories are enforced by the assessor. The
manifest does not choose which mandatory gates exist. Raising policy budgets is
supported; weakening the approved minimum native/coverage budgets cannot pass.
A root project LICENSE is also required. License choice is MIT; distribution
notices still require review.

Feature acceptance remains a substantive review responsibility. The assessor
checks identities, report structure, budgets and attachments; it cannot establish
reviewer independence or the truth of an arbitrary review assertion. Never create
fake reviewer identities, placeholder evidence or an approval from the coding
agent presented as independent. Synthetic positive controls live only in temporary
test directories and are not release evidence.

## Collection and migration

Prepare source/docs/package/policy changes before the final freeze. Each campaign
records exact source, binary and environment provenance; retain earlier failures
and their disposition. Uncommitted or untracked candidate changes block readiness.
A source change invalidates the candidate's evidence.
Do not bulk-convert historical reports to v2 or mark unavailable campaigns passed.
Missing required reports keep readiness blocked.

Run `tools/dune-pkg runtest tools --force` and `tools/dev selftest release` for
positive beta/production controls and negative freshness, corruption, budget,
experimental-scope and independent-review controls. Full `tools/dev validate`
also runs the release self-test and installed harness readiness checks.
