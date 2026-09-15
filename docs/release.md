# Beta and production release evidence

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

GitHub Actions is unavailable because its monthly quota is exhausted. Hosted CI
is not inspected or awaited. Policy v2 replaces it with reproducible local platform
evidence, and replaces AFL with the approved native campaign. Reports explicitly
record these replacements; neither unavailable CI nor skipped AFL is recorded as
passed. Restoring CI later is separate work, not a dependency of this plan.

## Native campaign and coverage requirements

Each target requires at least 1,800 seconds of completed child execution, 100,000
checked inputs and 20 distinct nonnegative 64-bit seeds. Seed spelling is
normalized before counting. Every batch must exit successfully, record its binary
identity and checked/skipped/generated counts, and satisfy their accounting.
Timeouts, skipped-only batches, reused seeds, incomplete regression replay and
unresolved findings cannot qualify. Source and binary identity must remain frozen.
The runner's checked-input accounting and long-campaign collection are subsequent
implementation slices; historical 420,000-trial smoke reports do not qualify yet.

Coverage minima are 95% core/codec/engine, 85% framework and 80% extensions. Reports
must retain visited/total points, a consistent computed percentage, missing-file
inventory and critical-path review. These are instrumented points, not branch
coverage or security percentages. Additional per-file controls and upstream
libraries are not erased by exceeding an aggregate threshold. Existing Bisect
instrumentation remains development-only, on the separate coverage lock.

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
| `native/<target>` | `target`, `mode: NATIVE`, `runs` with seed/status/exit/seconds/checked/skipped/generated/binary_sha256; `regression_inventory_replayed`, `negative_controls_passed`, empty `unresolved_findings` |
| `internal-review`, `reference-differential`, `proxy-observers`, `stable-performance`, `soak`, `contract-coverage`, `dependencies`, `packaging` | `reviewed_by`, `acceptance_passed: true`, empty `unresolved_findings`, with substantive supporting attachments |
| `support-scope` | Exact `features` inventory with `BETA_TESTED` status, `websocket: EXPERIMENTAL`, `public_production_claim: false` |
| `security-review`, `api-review` | `reviewer`, `approved: true`, `independent_of_implementation: true`, `identity_verified_by`, empty `unresolved_findings`; owner-verified independent review attachments |
| `private-reporting` | `verified_channel`, `verified_by`, verification evidence |

The exact feature and target inventories are enforced by the assessor. The
manifest does not choose which mandatory gates exist. Raising policy budgets is
supported; weakening the approved minimum native/coverage budgets cannot pass.
A root project LICENSE is also required. License choice is MIT; adding the text,
metadata and third-party notice review belongs to publication preparation.

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
The evidence collector and per-campaign validators will be extended alongside the
remaining plan slices; until their actual reports exist, readiness remains blocked.

Run `tools/dune-pkg runtest tools --force` and `tools/dev selftest release` for
positive beta/production controls and negative freshness, corruption, budget,
experimental-scope and independent-review controls. Full `tools/dev validate`
also runs the release self-test and installed harness readiness checks.
