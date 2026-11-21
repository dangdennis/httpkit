# Validation status

Updated 2026-09-18; database-layer entry added 2026-11-21 for the uncommitted
working tree. Library code baseline for the September results: `d39f021`; the
starter and documentation followed that baseline.

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

2026-11-21: the Lwt transport, application and client packages were removed; Eio
is the only runtime, and the Lwt results above are historical.

2026-11-21: PostgreSQL in `httpkit-db-eio` moved from Caqti/libpq to sqlkit's
pure OCaml driver, `sqlkit-pgwire`, pinned from Git; SQLite stays on Caqti. The
patched `caqti-driver-postgresql`, `postgresql.5.4.0`, `conf-postgresql` and the
local `toolchain/opam-fixes` repository were removed. `httpkit-session-eio` no
longer depends on Caqti. See [dependencies](dependencies.md#postgresql-driver).

| 2026-11-21 check (macOS arm64, working tree) | Result and scope |
| --- | --- |
| `tools/dune-pkg runtest` | Passed. |
| Fast harness tier | Passed, 150 cases. |
| `tools/dev databases` | Passed: "PASS PostgreSQL and SQLite". |
| `test/db_eio/db_test.ml`, `test/extensions/sql_session_test.ml` | Passed on SQLite and on PostgreSQL through the new driver. |
| `tools/dev consumer framework`, `tools/dev consumer extensions` | Passed. |
| Starter as bytecode | `examples/starter/main.bc`, run via `tools/dune-pkg exec`, saved and listed a note against PostgreSQL 18. |

Not re-run on 2026-11-21: coverage, mutations, fuzz, soak and load campaigns,
Linux validation, and the opam-switch installation. Every database-layer result
in the September table — the PostgreSQL two-hour soak, coverage and mutation
figures, Linux validation and the starter's PostgreSQL checks — was obtained on
the Caqti PostgreSQL path and is historical for it. It is not evidence about the
new driver. The driver's authentication and TLS code is new and has not had an
independent review.

Earlier results are history, not fresh acceptance for a different source hash.
The Linux runs used amd64 emulation on an arm64 host; they establish compatibility,
not native Linux throughput. Client measurements include the local fixture server.

## What we found

**PostgreSQL bytecode — closed 2026-11-21 by removing the binding:** in
September both the separately installed starter and the then-current
in-repository bytecode build crashed with
SIGSEGV in `PQsendQueryParams_stub`, called by `PQsendQueryParams_stub_bc`, in the
pinned `postgresql.5.4.0` binding. Its six-argument bytecode wrapper was a suspected
calling-convention defect; no dependency patch was applied or validated.
Native execution passed with both databases. The defect was never diagnosed or
fixed: the binding is no longer a dependency, and PostgreSQL has no C stubs on
the new path. On 2026-11-21 the in-repository starter built as bytecode saved
and listed a note against PostgreSQL 18. That is one bytecode run of one
program; the separately installed (opam) starter was not repeated.

**PostgreSQL driver — new, one review:** the replacement driver's
authentication (trust, password, MD5, SCRAM-SHA-256 without channel binding)
and TLS code had one adversarial review on 2026-11-21, which included a scripted
hostile server. It found twelve issues, three of them high severity (host name
not checked under `verify-full` for some names, message lengths wrapping at
4 GiB, and no authentication-method policy). All are fixed in the pinned commit
`079ed9e` with regression tests. That review was produced with the same tooling
that wrote the driver; there has been no review by an independent party.
`sslmode` defaults to `prefer`, which does not verify the server certificate,
and the password itself is sent only over TLS or a Unix socket unless
`require_auth` says otherwise. Earlier PostgreSQL fault, soak
and cancellation campaigns ran against libpq and have not been repeated.

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

**Production testing of the PostgreSQL path, 2026-11-21 (second pass):** run
against the driver before and after its fixes; the pinned commit is `079ed9e`.

- *Descriptor leak, fixed in the pin.* The driver leaked one socket for every
  TCP connect that failed. Through the starter, a 20-second database outage
  took the process from 20 to 814 descriptors, and with a limit of 128 a
  6-second outage ended it with `Too many open files`. After the fix, 400
  requests with the server stopped left the count unchanged (15 before, 14
  after), using a `localhost` URL, which previously leaked on every connection.
- *Commit reported as success after a rollback, fixed in the pin.* Behind
  PgBouncer in transaction mode a migration returned normally and created
  nothing. A COMMIT that the server answers with `ROLLBACK` is now an error.
  The session-store test passes through PgBouncer with and without
  prepared-statement support, and the tables exist afterwards.
- *Statement-name collisions behind PgBouncer, fixed in the pin.* Two clients
  sharing a backend could receive each other's rows. Statement names are now
  derived from the SQL. `create` takes `~statement_cache:false` for poolers
  without prepared-statement support.
- *Faults through the HTTP stack (previous pin `77241d9`).* 12 workers for ten
  minutes with backends terminated every few seconds, a server restart and
  15- and 45-second pauses: 93,670 writes acknowledged, all present, none
  duplicated; recovery within 5 to 50 ms of each fault ending; no request
  past 30.0 s; the process never hung. Fourteen writes that returned 500 had
  in fact committed, which is the documented unknown-outcome case.
- *Soaks (previous pin).* 20 minutes on PostgreSQL and 10 on SQLite with no
  unexpected error and flat memory and descriptors. The PostgreSQL soak issues
  about two database statements a second, so it says little about load.
- *Coverage.* Core 95.37%, framework 86.15%, extensions 84.35%.
  `httpkit_db_eio.ml` is at 78.8%: `Null` values, the nested-transaction and
  closed-pool guards, quoted placeholders and the checksum-mismatch branch are
  not exercised.
- *Linux x86_64 container.* `tools/dev validate` passed. `tools/dev databases`
  failed because the driver required a user name and the container had no
  `USER`; the pinned driver now falls back to the account the process runs as.
  Not re-run on Linux since.
- *Not re-run against `079ed9e`:* the ten-minute fault run, the soaks, coverage
  and the Linux container. Re-run on it: the database and session tests on
  both backends and through PgBouncer, `tools/dev databases`, `tools/dev
  validate`, and the outage descriptor check above.
- PostgreSQL 15 is the oldest supported server. Older ones are not refused and
  not tested.
- Unrelated to these changes: fresh OCaml toolchain builds fail on this
  machine's current Xcode SDK (`pipe2` is weak-linked and absent at run time),
  so `_build-pkg-5.5.0` cannot be recreated here without
  `ac_cv_func_pipe2=no`; four AFL targets each saved one timeout that does not
  reproduce on replay; the starter's accept loop treats `EMFILE` as fatal.

## What remains

- Resolve or explicitly bound the applicability of the hang before broad rollout.
- Obtain an independent review of the PostgreSQL driver's authentication and TLS code.
- Repeat the PostgreSQL soak, fault, coverage, mutation and Linux checks on the new driver.
- Re-validate the opam-switch installation with the sqlkit Git pins, including bytecode.
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
