# Composable web framework roadmap

Scope: complete the web application layer above httpkit, Eio first, with both
PostgreSQL and SQLite. Keep runtime-neutral protocol helpers independent of the
server and database packages. Existing APIs remain available. README stays brief.
AFL execution and its two unresolved timeout findings remain deferred by request.

The [protocol library plan](protocol-libraries-plan.md) covers the next libraries:
headers, compression, files, TLS, clients, HTTP/2, WebSocket additions and HTTP/3.
It specifies package boundaries, reuse decisions, staged delivery and acceptance.

## Delivery sequence

| Stage | Deliverable | Acceptance boundary | Status |
| --- | --- | --- | --- |
| F1 | Bounded URL/query/form, JSON, response and HTML helpers | malformed encodings, duplicate fields, depth/size limits, injection controls | Implemented; final acceptance pending |
| F2 | Eio application dispatch and server lifecycle | real socket requests, streaming, early rejection, cancellation, graceful signal shutdown | Implemented; final acceptance pending |
| F3 | Request IDs/logging, recovery, CORS, security headers, proxy policy | no credential logs, fail-closed origins/proxy trust, cancellation propagation | Implemented; final acceptance pending |
| F4 | Cookies, sessions, CSRF and authentication integration | opaque random IDs, expiry/revocation/rotation, duplicate credential rejection, contextual escaping | Implemented; final acceptance pending |
| F5 | Incremental multipart uploads | fragmentation invariance, limits before retention, aborted-upload cleanup, filenames never paths | Implemented; final acceptance pending |
| F6 | Static content and HTML rendering | traversal/symlink safety, MIME types, validators, HEAD and conditional requests | Implemented; final acceptance pending |
| F7 | SSE and WebSocket helpers | UTF-8/framing vectors, partial I/O, bounded messages, ping/close/cancellation | Implemented; final acceptance pending |
| F8 | Caqti Eio PostgreSQL and SQLite integration | real transactions/rollback, bounded pooling, migrations with serialization and checksums | Implemented; final acceptance pending |
| F9 | Composed application, installed consumers, docs and acceptance | native/bytecode consumers, adverse requests, profile and 30-minute/2-hour soaks | Implemented; final acceptance pending |

After each working slice, review and refactor code quality: simplify ownership and
error paths, remove duplication, check public API consistency, and keep comments
limited to contracts and non-obvious decisions. Rerun affected checks after edits.

Each stage requires explicit public interfaces, positive and negative controls,
seeded properties where useful, resource accounting for owned I/O, and focused
regressions. Freeze the completed sources before final sustained measurements.
Check real backend behavior rather than substituting mocks for database guarantees.

## Ownership and defaults

- Core helpers perform no I/O and do not consume bodies implicitly.
- Eio handlers own one incoming body reader; returned streaming responses own their
  producer lifetime. Exceptions after response start abort the transport.
- Application authentication supplies verification callbacks; the framework does
  not invent password hashing, JWT verification, OAuth or database wire protocols.
- Browser sessions use server-side opaque tokens from a cryptographic random
  source. Persistence is explicit; an in-memory store is not multi-replica storage.
- Trusted proxy headers require explicit peer trust; application limits remain
  active behind Railway. No deploy or provisioning is implied by implementation.
- External libraries remain optional integrations in separate dependency closures.

## Current implementation

All nine stages are implemented. Focused pure/runtime tests, both real database
backends, and four compiled mutation controls have passed locally. Final acceptance
requires fresh installed-consumer, coverage, regression and sustained-load reports
for one unchanged source hash. The 30-minute SQLite canary and two-hour PostgreSQL
soak remain required; historical HTTP-only results do not satisfy these gates.
Detailed measured status lives under `_artifacts/framework/`.

## Evidence and release

Retain exact commands, source hashes, failures and measured budgets under
`_artifacts/framework/`. Keep the full existing regression suite and both native
adapters covered. Public security/API review and hosted-platform evidence remain
separate from local implementation completion. No finite soak or coverage score
proves the absence of security defects.
