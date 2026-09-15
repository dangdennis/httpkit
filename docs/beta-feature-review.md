# Beta feature and ownership review

Review started 2026-09-14 against `1186858`, followed by the static-path controls
listed below. This is an internal implementation review, not independent security
approval. [The beta plan](beta-plan.md) owns acceptance; this matrix records what
each feature must preserve and where the executable evidence lives. Final reports
must match the frozen candidate, rather than inheriting historical PASS statuses.

| Feature | Invariant and ownership boundary | Existing controls / remaining acceptance |
| --- | --- | --- |
| HTTP1 | Strict framing, terminal failure, bounded progress; no ambiguity crosses exchanges | `test/http1`, segmented CL/TE/chunks/trailers/EOF/special responses; long native and differential campaigns pending |
| Engine | Connection-specific exchange IDs; bounded queues; accepted bytes acknowledged once | `test/engine`, engine scenarios and partial-write/isolation properties; capacity and slow-client campaign pending |
| Eio | Owned handler/reader/writer cleanup joins before transport close; shutdown stops admission | `test/adapter`, `test/production`, `test/web_eio`; real 64-connection and shutdown stress pending |
| Lwt | Same close/join contract, including suspended finalizers and losing deadline branches | `test/adapter/lwt_test.ml`, `test/extensions/lwt_app_test.ml`, production controls; correctness stays in scope, performance parity deferred |
| Routing/middleware | Raw captures remain raw; ambiguous scalars rejected; proxy metadata requires immediate-peer trust | Router/middleware tests, installed negative API controls, `test/web/proxy_test.ml`; deployed proxy contract unverified |
| JSON/forms | Byte/depth/field bounds, JSON duplicate rejection, exactly one URL decoding step | `test/web/web_test.ml`, URL/forms generators; final extension coverage and critical-path review pending |
| Streaming/SSE | Producer owns submitted strings; send applies backpressure; HEAD never starts a producer | Adapter/application/production tests and SSE encoding controls; slow readers and sustained capacity pending |
| Static | Confined root; decoded traversal/control rejection; no nonregular reads; bounded collected content | Framework interop plus `test/web_eio/runtime_test.ml`: internal/escaping/dangling symlinks, FIFO, directory, NUL/separators, HEAD and limits; broader filesystem-race/platform evidence pending |
| Uploads | Generated exclusive names; filename is metadata; callback and partial-file cleanup owns deletion | Multipart segmentation/quotas/control-byte tests; runtime ENOSPC/write/close/retryable unlink/cancellation controls; persistent filesystem failure remains an application-visible error |
| Cookies/sessions | Authenticated cookie payloads; explicit expiry/rotation/replay semantics; memory/SQL resources stay scoped | `test/web/web_test.ml`, `test/extensions/auth_test.ml`, `sql_session_test.ml`; final concurrency/capacity evidence pending |
| Database | One scoped lease owner; bounded users/waiters; rollback before release; shutdown never reopens | `test/db_eio/db_test.ml` with SQLite/PostgreSQL, migration and cancellation controls; backend disconnect/rollback failure combinations and fresh long soaks pending |
| Password | Upstream Argon2 only; reject cost bombs before native work; bound off-loop verification admission | `auth_test.ml` and installed consumers cover policy/hash/verify; `examples/passwords/worker_test.ml` covers one-worker admission/cancellation/native work; sustained mixed-load evidence pending |
| OIDC | Upstream JOSE verification plus exact local claims; browser binding consumed once; remote work bounded | `auth_test.ml`, `oidc_eio_test.ml` cover signature/claims/duplicates/replay/cache/capacity/deadlines; real configured HTTPS-client/provider contract remains application/deployment work |
| WebSocket (experimental) | Masking, UTF-8, fragmentation and limits; one callback/write owner; absolute closing deadline | Web tests, segmented/allocation controls, runtime close/partial-write/cancellation tests; full security campaign and independent review remain open |

## Findings and dispositions

- Multipart trimming concealed illegal controls. `15c2b6d` rejects raw controls
  before normalization; every control byte is exercised across segmentation.
- WebSocket prefix/suffix copying grew quadratically. `b50aca8` uses an append
  buffer and parse cursor; native and bytecode allocation controls and segmented
  semantics pass. This fixes a measured defect without changing experimental status.
- Oversized raw engine replays falsely reported PASS. `1186858` centralizes guards,
  exports checked/skipped/failed counts and rejects skipped raw replay. Generated
  inputs now exercise length boundaries beyond Crowbar's old64-byte generator.
- Static nonregular and symlink policy had incomplete direct regression coverage.
  Added real filesystem controls pass without changing the implementation.
- The Eio guide incorrectly claimed the application layer was Eio-only. It now
  links the implemented Lwt package and documents the guide's actual scope.
- Historical request/core timeout artifacts are generator entropy. Their original
  causes remain unknown. [Investigation notes](request-timeout-investigation.md)
  prevent a raw-parser replay or changed generator from being mislabeled resolution.
- `auth_boundaries_test.ml` adds authenticated-but-invalid cookie payloads,
  cookie configuration/clock/header limits, pre-native password/hash guards, and
  OIDC metadata/callback/token-document rejection. Cookie fixtures use upstream
  AEAD with a test key to reach validation beyond authentication; no cryptographic
  algorithm is implemented locally. Authorization-code form escaping is checked
  separately from callback policy. SQL session HTTP middleware and additional
  backend fault combinations remain separate acceptance work.

## Contracts that remain the application's responsibility

Memory sessions use a single-domain store; yielding callbacks require external
synchronization. Encrypted cookies remain replayable until expiry and do not
provide server-side revocation. SQL sessions provide explicit revocation/atomic
rotation; pruning and durable storage capacity are operational policies.

Caqti connections must not escape or be shared outside their lease callback.
The public connection alias does not statically prevent escape. Closing a pool
inside its own lease would wait for itself and is unsupported. A custom finalizer
must terminate; cancellation initiates cleanup, it cannot justify abandoning an
owned file, transport or database lease.

Static roots must contain deliberately public assets. Hidden-path rejection is
based on decoded requested segments; it is not a scan of symlink target names or
file contents. Confined links within the public root are permitted. Do not place
private material in a public root or rely on a hidden basename as authorization.
HEAD still reads/hashes the bounded file; this is intentionally small static
serving. Upload callbacks must explicitly copy durable data before returning.

Password calls must run in bounded separate domains/processes. Each accepted
verification can allocate up to256MiB in the upstream library; a512MiB app profile
cannot safely admit arbitrary parallel password work. No custom cryptography or
unbounded background worker is justified by this review. The tested Eio example
admits one job and retains its slot through cancellation until native work ends;
it is application-owned integration, not an additional public package.

OIDC's supplied client must validate TLS, refuse redirects, bound response reads
and support cancellation. Coordinator timeout tests cannot certify an arbitrary
HTTP callback. Pending logins are process-local. Proxy recipes must validate
isolation and metadata normalization before forwarding headers become trusted.

The remaining rows are explicit acceptance work, not silently closed findings.
No production feature rewrite or new package was justified by this pass.
