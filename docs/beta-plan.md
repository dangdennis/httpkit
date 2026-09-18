# Public beta plan

Approved 2026-09-14. The public beta target remains GitHub prerelease
`v0.1.0-beta.1`, opam version `0.1.0~beta1`, MIT, with source-pin installation and
no central opam submission. It has not been published.

For today's results and open issues, read [validation status](status.md).
For a new private application, use [the GitHub/database tutorial](internal-use.md).
This plan records public release scope, not current approval.

## Scope

Existing HTTP, application, authentication, session, database and upload features
are in scope. WebSockets remain experimental. The streaming HTTP/HTTPS client
supports uploads and bounded origin pools; its API review remains deferred by
request. HTTP/2/3, new infrastructure, custom cryptography and speculative package
expansion are outside this work.

Eio is the first deployment target. Lwt correctness is required; benchmark parity
is deferred. Railway direct is the planned hosted topology, with Caddy optional.
No hosted environment is implied by passing local tests.

Implementation and validation outcomes live in [status](status.md). Historical
results cannot transfer to a changed source hash.

## Acceptance requirements

[Release policy](release.md) defines the exact inventories, fingerprints and
report contracts. Keep its requirements intact:

- Native fuzz: each of 14 targets needs 1,800 successful child seconds,
  100,000 checked inputs and 20 distinct seeds, with no unresolved findings.
- Coverage: at least 95% core/codec/engine, 85% framework and 80% extensions;
  all seven curated mutations must compile and be detected by real tests.
- Platforms: OCaml 5.5.0 on local macOS arm64 and Linux x86_64, installed
  native/bytecode consumers, plus required interoperability lanes.
- Capacity: exercise 1/16/64 connections and overload. Keep RSS below 512 MiB,
  post-warmup RSS growth within 32 MiB, equivalent-idle live heap within 1 MiB,
  descriptors within two of baseline, zero unexpected errors and complete cleanup.
- Sustained work: SQLite 30 minutes, PostgreSQL two hours, idle/slow/overload
  campaigns, and five 30-second endpoint samples at each selected concurrency.
- Deployment: verify real proxy trust, TLS, persistence, shutdown and recovery;
  timings from shared or emulated hosts remain advisory.

## Workflow and approvals

Work on main in small validated commits. Freeze source, docs, locks and tools
before collecting release evidence; preserve failed and interrupted attempts.
Do not fabricate missing approvals or convert historical reports into current ones.
Hosted CI and AFL remain excluded; use the approved local/native checks.
API review remains deferred.

Approve the exact hosted resource/cost plan before creating paid staging. Approve
the prepared beta before publishing it. A production claim additionally requires
the independent security/API reviews defined by release policy. Neither an internal
setup guide nor a successful push waives those requirements.
