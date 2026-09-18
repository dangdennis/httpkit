# Production-readiness audit map

Historical inspection; findings below describe that revision. See [current status](../status.md) for later fixes and validation.

Baseline: `88c8ed5`, 2026-09-14. This is a repository inspection and an initial
correctness-test slice, not an independent security audit or production approval.
No new feature packages are justified by this audit.

## Architectural map

| Layer/packages | Execution and ownership | Evidence entry points |
| --- | --- | --- |
| `httpkit-core` | Checked immutable values, ordered duplicate-preserving headers, body-polymorphic requests; no I/O dependencies | `lib/core`, `test/core`, `docs/design.md` |
| `httpkit-http1` | Byte-scanning head/body state machines; consumed-prefix API, terminal errors, strict framing; core + ipaddr | `lib/http1/httpkit_http1.ml`, `test/http1`, `docs/http1.md` |
| `httpkit-engine` | One exchange per connection; independent receive/send progress, one pending event, bounded output; IDs include connection identity | `lib/engine`, `test/engine`, `docs/engine.md` |
| `httpkit-transport-eio`, `-lwt` | Native read/write loops drive engine; clocks/deadlines, transport close, cancellation and handoff | `lib/eio`, `lib/lwt`, `test/adapter`, `docs/adapters.md` |
| `httpkit-router`, `httpkit-middleware` | Raw-path routing, method outcomes; pure wrappers/context transitions | `lib/router`, `lib/middleware`, matching tests/docs |
| `httpkit` | URL/forms, JSON, replies, HTML, cookies, memory sessions, multipart, SSE, server WebSocket codec | `lib/web`, `test/web`, `docs/framework.md` |
| `httpkit-eio`, `httpkit-lwt` | Connection dispatch -> scoped request reader -> route/middleware/handler -> fixed/streaming/upgrade response; native lifecycle | `lib/web_eio`, `lib/web_lwt`, `test/web_eio`, `test/extensions/lwt_app_test.ml` |
| Eio files/uploads | Capability subtree, checked paths, bounded file collection, generated exclusive temporary paths and cleanup | `lib/web_eio/files.ml`, runtime tests |
| `httpkit-db-eio` | Bounded Caqti resources/waiters, transaction rollback and migration serialization | `lib/db_eio`, `tools/devlib/databases.ml`, DB integration tests |
| `httpkit-cookie`, `-session-eio` | Upstream authenticated encryption or SQL token digests; expiry/rotation/revocation; distinct opaque backends | `lib/cookie`, `lib/session_eio`, `test/extensions` |
| `httpkit-password` | Bounded Argon2 costs; synchronous native call, caller owns worker admission | `lib/password`, `docs/extensions.md` |
| `httpkit-oidc`, `-oidc-eio` | Upstream signature/PKCE support plus strict local claims; scoped remote operations and process-local pending flows | `lib/oidc*`, extension tests |
| Harness/fuzz | Synthetic contract/model/shrinker plus real cases; nine catalog targets and native adapter schedules | `test/support`, `test/self`, `fuzz`, `toolchain/fuzz-targets.json` |
| Performance | Microbenchmark catalog, external parser lanes, real transport streaming, framework load/profile/resource controls | `bench`, `tools/devlib/{benchmarks,performance,load}.ml` |
| Release/tooling | Locked compiler, installed native/bytecode consumers, coverage lock, curated mutations, source-matched release predicates | `tools/devlib`, `toolchain/release-policy.json`, `docs/release.md` |

Public package catalog: 17 entries including the development harness, as listed
in `docs/design.md`; package count does not imply any package is release approved.

Hot path: socket -> adapter staging -> `Engine.offer` -> head/body codec -> checked
metadata/event -> application request -> router/middleware -> handler -> response
-> encoder/output FIFO -> partial write acknowledgement. Body events own strings;
retaining them transfers memory responsibility to the application. HEAD suppresses
stream producers. Early final responses and explicit discard have different
connection-reuse semantics. Upgrade handoff transfers transport ownership.

## Concrete findings

| ID | Evidence and finding | Priority/action |
| --- | --- | --- |
| A01 | `docs/release.md` says seven packages; design lists 17 including harness. Design ends with obsolete implementation-next steps. | P0: correct scope/docs now; link one active backlog |
| A02 | `SECURITY.md` excludes WebSocket framing while substantial parser/runtime support exists. This is a claim gap, not proof of a vulnerability. | P0: label WebSockets experimental; P1 campaign before support claim |
| A03 | `test/http1/http1_cases.ml` tests every single split for heads; invalid chunk cases use one schedule. `fuzz/http1_fuzz.ml` compares whole/one-byte only and synthesizes EOF on no progress rather than exercising every EOF API path. | P0: reusable deterministic segmentation controls first, then share with fuzz |
| A04 | `Common.proxy` is duplicated in Eio/Lwt; it requires explicit immediate-peer trust, one X-Forwarded-For IP, one scheme and no Forwarded. It does not model X-Forwarded-Host or a multi-hop chain. | P0: preserve fail-closed default; specify/verify each topology before expanding |
| A05 | `Common.access_log` measures handler return, before response streaming completes, and is not a transport observation API. Eio/Lwt repeat pure CORS/Vary/proxy policy. | P1: explicit duration meaning, observation hooks; consolidate pure policy only with parity tests |
| A06 | `Websocket.feed` appends to `pending` and slices remaining input; a large frame supplied a byte at a time repeatedly copies its prefix. Complete messages also copy into a Buffer. | P0 profile; P1 campaign. Candidate allocation hotspot, no benchmark improvement claimed |
| A07 | Multipart `locate` compares allocated substrings at candidate positions; retained buffers have explicit bounds. | P0 profile hostile boundary prefixes before optimizing; add upload cleanup/disk-failure cases |
| A08 | `Files.static` collects and hashes the entire bounded file, including HEAD, default 8 MiB. Hidden segments are rejected; Eio subtree confinement is used. | Keep small. Measure HEAD/static cost; do not build an asset platform or advanced ranges |
| A09 | Limits are spread across codec, engine, timeout, app, multipart, JSON, sessions and DB constructors. Low-level body quota is optional; application body default is finite. | P0: inventory units/owners/defaults and compose aggregate budgets; do not call every optional low-level quota unsafe |
| A10 | Fuzz catalog has no router/URL/form/multipart/WebSocket selectors. Framework tests exist, but are not those campaigns. AFL runner exists and is explicitly skipped by user. | P0: generated OCaml campaigns and persisted regressions; explicitly reconcile release policy without fabricating AFL evidence |
| A11 | Performance/load tools already collect latency/resource evidence; historical benchmark docs explicitly report noisy timing and ownership-sensitive comparisons. | P0: reuse them, add fixed endpoint baseline/profile matrix and stable comparison rules |
| A12 | Runtime adapters and applications have separate cancellation/close paths and tests; inspection alone cannot prove every SIGTERM/disconnect interleaving. | P0: resource ownership matrix plus deterministic fault schedules and real socket stress |
| A13 | OIDC remote callback owns bounded HTTPS reading; pending flows are process-local. Password hashing is synchronous and needs bounded domains/processes. | P0 documentation/default review; integration findings gate rollout, not automatic new client/worker packages |
| A14 | Cookie and SQL sessions intentionally differ: copied cookies remain replayable to expiry; SQL supports revocation. DB transactions use explicit rollback/cleanup. | P0 verify concurrent rotation/cancellation and scoped lease escape; do not merge distinct semantics |
| A15 | `toolchain/release-policy.json` and release docs still focus on older evidence families and AFL-duration requirements. New features need an explicit evidence inventory. | P0 release inventory; retain NOT_READY until missing campaign/platform/review evidence exists |
| A16 | Prior roadmap planned headers/clients/codecs/download/WS packages by default and required Caddy first. | Removed as mandatory work. Railway direct is canonical; Caddy and new packages require demonstrated application need |

No dead production abstraction was proved safe to delete in this pass. The TLS/
codec probes and private native-close experiment remain isolated development
research, not commitments to publish packages. They should not block P0 work.
The layer boundaries are meaningful; duplication of pure runtime policy is a
review target, not justification for a universal monadic adapter rewrite.

## Inspection coverage and limits

Read current design, HTTP/1, engine, adapter, routing, middleware, framework,
extension, security, release, benchmark, harness and roadmap documentation.
Inspected package dependencies/interfaces, parser and engine states, transport and
application cleanup paths, proxy/logging policy, WebSocket/multipart/file code,
auth/session/DB boundaries and test/fuzz/benchmark/release entry points. Findings
above identify source entry points so later slices can review deeper paths.

This is broad architectural inspection, not exhaustive line-by-line verification
of every path. No independent audit, Railway deployment trace, stable performance
baseline or long fuzz/soak campaign was performed here. Unknowns stay backlog items.

## First smallest P0 step

Make HTTP/1 corpus segmentation reusable across whole input, byte input, every
single split, deterministic random multi-splits and short codec work budgets.
Check semantic outcomes, exact success boundaries, progress, EOF and terminal
failure. Add malformed response and chunk/trailer cases that currently lack the
same segmentation coverage. This changes test evidence first; change production
code only if a reproducible discrepancy is found.
