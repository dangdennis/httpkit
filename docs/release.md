# Release evidence and remaining gates

The code now contains seven independently usable production packages: core values, HTTP/1 codecs, a sans-I/O engine, native Eio/Lwt drivers, middleware, and routing. M7 makes release assessment executable. It does not manufacture independent approval or replace long campaigns with smoke runs.

## Commands

```sh
tools/dev coverage
tools/dev mutations
tools/dev fuzz --seconds 30
tools/dev selftest release
tools/dev release --output _artifacts/release.json
```

The standalone release command returns exit 3 and `NOT_READY` whenever a required gate is missing, stale, below budget, or failed. Exit 0 means the checked evidence is complete. An artifact's `status: PASS` describes its own scope; it does not imply release readiness. `toolchain/release-policy.json` records the actual thresholds and required evidence families.

Both `tools/harness readiness --release` and `tools/harness readiness --milestone M7` run the same detailed assessment and preserve exit 3 for incomplete evidence. See the [manual M7 completion checklist](m7-manual-checklist.md) for ownership, commands, and required review artifacts.

Nine separately selected fuzz targets cover core values; request, response and chunked codecs; server and client lifecycles; partial writes; native adapter schedules; and connection isolation. `toolchain/fuzz-targets.json` records their executable and selector. Each target receives an AFL time budget, retains its corpus and logs, and replays every retained queue entry without instrumentation. The native adapter target checks partial I/O and cancellation with both runtimes. It sends no network traffic.

A release-duration command is `tools/dev fuzz --seconds 28800`. That schedules eight hours **per target**, up to 72 hours of fuzz CPU across all nine. Use `--target request` (or another catalog name) to run one independently. Run this only against a frozen release candidate: any source change makes evidence stale. Current 30-second campaigns are smoke evidence and do not satisfy that gate. Campaign completion also does not remove the need to triage findings or review generator depth.

## Coverage and mutation evidence

Coverage has its own committed `coverage.lock` and `dune-workspace.coverage`, using OCaml 5.5.0 and ppxlib 0.38.0. Normal builds use `dune.lock` with the same compiler. The separate lock adds development instrumentation dependencies; it is not a compiler compatibility lane. The backend is optional and never enters a production package's required dependency closure. Bisect is pinned to commit `7061d643ff492b0045796357ee6917ded21fb1f0` from [upstream PR #448](https://github.com/aantron/bisect_ppx/pull/448), which adapts instrumentation to the modern PPX AST and supports Cmdliner 2. This is an unmerged upstream patch, not a released Bisect version; coverage must be verified when changing that pin. [Dune instrumentation](https://dune.readthedocs.io/en/stable/instrumentation.html).

The coverage report records the measured core/codec/engine instrumented-point percentage and checks for missing executable source files. Module aliases in `lib/core/httpkit_core.ml` have no executable points and are the sole inventory exclusion. No executable branches are marked `coverage off`. Per-file results remain visible: engine coverage is lower than codec coverage, and adapters are assessed with their fault/lifecycle tests as well as point reports. This is not a branch-coverage percentage or evidence that all defects are absent.

Uncovered points remain in the denominator. They include large-counter overflow guards, combinations rejected earlier by opaque constructors or framing validation, additional upgrade/error combinations, and alternate paths within compound conditions. The HTML and line reports identify exact locations. Independent review must assess those gaps; this implementation does not waive them merely because the aggregate exceeds 95%.

Forked tests explicitly dump native counters before `_exit`, through a test-only module selected only when Bisect is available. Normal harness builds use a no-op implementation. This avoids both losing child coverage and running inherited parent exit hooks.

The mutation runner copies source into a temporary project and uses the active locked compiler/dependency closure. It first requires passing baseline suites. It then weakens CL+TE rejection, cross-connection ID ownership, and output accounting one at a time. Each mutant must compile and fail a real test suite. Compilation failures and timeouts do not count as kills. These three curated mutations are a positive control, not an exhaustive mutation score.

## Evidence requiring additional work or review

The report also requires the complete remote platform matrix, independent security review, API review, broader reference/differential evidence, proxy wire/backend/application observation, a stable paired performance baseline, sustained soak runs, and a reviewed mapping of all applicable contracts. The implemented Nginx/http/af/curl smoke lanes do not claim to be the entire planned Hyper/httpun/HAProxy comparison matrix.

Review artifacts must refer to the exact source hash and real supporting files, record a reviewer/approver, and list no unresolved findings. The machine checks the fields and freshness; a maintainer must verify reviewer identity, independence, and the contents of the evidence. Hand-written placeholder approvals are not reviews. No such independent approvals are created by the build agent.

Licensing and a verified private vulnerability-reporting channel remain owner decisions before publication. See [SECURITY.md](../SECURITY.md). Package publication, public repository visibility, and a security recommendation are distinct from committing and pushing the implementation.
