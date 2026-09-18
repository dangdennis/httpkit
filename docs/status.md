# Validation status

Updated 2026-09-18. Library code baseline: `d39f021`; the starter and documentation
follow that baseline.

The libraries have substantial local test coverage. They are **not yet signed off
for broad internal deployment or production**. Prepare internal applications using
[the new-application guide](internal-use.md); public beta and production retain
[their existing release gates](release.md).

## What passed

| Check | Result and scope |
| --- | --- |
| Local validation | Full macOS validation, API documentation builds, installed native/bytecode consumers, runtime isolation and integration checks passed on `d39f021`'s source contents. |
| Client campaign | All 12 Eio/Lwt HTTP/HTTPS fetch, pool and slow-consumer scenarios passed 2,000 iterations each after the fixture fix in `7330082`. Every scenario reported zero file-descriptor growth. |
| Linux clients | Client suites passed on Linux x86_64 with the same fixture-fix source fingerprint. |
| Earlier candidate campaigns | On `ef12cbf`: 14-target native fuzz campaign, Linux validation, SQLite 30-minute canary, PostgreSQL two-hour soak, slow-input/blocked-output campaigns and 30-minute capacity checks at each of 1/16/64 connections completed successfully. |
| Earlier coverage | On `ef12cbf`: core 95.37%, framework 87.11%, extensions 84.83%, plus seven detected curated mutations. These are instrumented-point measurements, not a security score. |
| New-application starter | Native SQLite and PostgreSQL route, invalid-input, parameterized-query, restart/migration and SIGTERM checks passed. The copied app also passed natively in a separate Dune project using the previously installed `ef12cbf` packages. SQLite bytecode passed; PostgreSQL bytecode crashed at startup. This checks application wiring, not a fresh GitHub installation or candidate release. |

Earlier results are history, not fresh acceptance for a different source hash.
The Linux runs used amd64 emulation on an arm64 host; they establish compatibility,
not native Linux throughput. Client measurements include the local fixture server.

## What we found

**PostgreSQL bytecode — blocked:** both the separately installed starter and the
current in-repository bytecode build crashed with
SIGSEGV in `PQsendQueryParams_stub`, called by `PQsendQueryParams_stub_bc`, in the
pinned `postgresql.5.4.0` binding. Its six-argument bytecode wrapper is a suspected
calling-convention defect; no dependency patch has been applied or validated.
Native execution passed with both databases. The starter guide uses native builds;
earlier bytecode consumer passes do not establish PostgreSQL bytecode safety.

**Client fixture isolation:** IPv4-only listeners used `localhost`, which could
resolve to an unrelated IPv6 listener on the same port. A controlled collision
reproduced the reset. Fixtures now use `127.0.0.1` with a matching test certificate;
trust and hostname rejection tests remain enabled. The original intermittent
reset did not record its peer, so that individual failure's attribution is inferred.

**Profiling hang — unresolved:** three long runs stopped after 122 of 125 epochs,
during large-stream responses at 64 connections. Other full runs passed. The latest
capture showed 56 load workers waiting to reacquire the OCaml runtime lock while
eight finished. The server answered its health check and the sampler kept running.

A standalone raw-socket/allocation test also stalled without httpkit, HTTP or a
server, with similar runtime-lock stacks. This is evidence against an exclusively
HTTP-level cause. It does not yet identify the OCaml/macOS cause or prove deployed
applications cannot encounter it. Simpler yield, select, thread-turnover and
read/allocation controls passed. See [the investigation](profiling-hang.md).

The [historical AFL timeout findings](request-timeout-investigation.md) also remain
unresolved; their investigation is deferred. They are separate from the profiling hang.

## What remains

- Resolve or explicitly bound the applicability of the hang before broad rollout.
- Diagnose and validate the PostgreSQL binding before supporting database bytecode builds.
- Freeze the internal candidate and collect fresh package/consumer/platform checks.
- Exercise the actual application's proxy/TLS, database, limits, shutdown and rollback.
- Record deployment owners, monitoring and recovery procedures.
- Complete dependency/native-library review for the deployed image.

API review remains deferred by request. Independent review and other public
release requirements have not been waived. No hosted deployment or publication
has occurred as part of these checks.

## Evidence locations

Raw evidence is retained locally under `_artifacts` and is not shipped in the
repository. `acceptance61/61b/61c/61d` contain the earlier candidate campaigns;
`acceptance62` contains the fixture fix and completed client measurements;
`acceptance63` contains diagnostic validation and the captured profile stall;
`acceptance64` contains the standalone controls; `acceptance65` contains the
starter and documentation checks. Failed and interrupted attempts
remain alongside successful runs. Terminal supervisor results override stale
`RUNNING` reports left by killed processes.
