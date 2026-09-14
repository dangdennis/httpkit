# Lifecycle and ownership review

This matrix separates the implemented ownership model from remaining acceptance
work. P0-03/P0-10 stay open until runtime, application and external-resource fault
schedules have source-matched evidence. A library cannot force a custom callback
or finalizer that never yields or never terminates to clean up safely.

| Resource | Owner / close authority | Cancellation, escape and concurrency | Next evidence boundary |
| --- | --- | --- | --- |
| Listener/backlog | Caller of `serve` / `serve_connections` | Caller stops admission and closes listener; accepted transports transfer to workers | SIGTERM at each admission boundary |
| Connection transport | `with_connection`, then successful claimed handoff recipient | One domain/event loop; cancel and join callback, reader and writer before one close; first failure wins | Reset/half-close and simultaneous faults |
| Engine/exchange | Connection driver | One mutable owner, opaque connection-specific IDs; abort idempotent; queues discarded on abort | Interrupted sequencing and queue accounting |
| Request reader | Active application exchange | Scoped and single-reader; cannot safely outlive handler/response scope | Suspended concurrent read and scope retirement |
| Handler/response producer | Application exchange/connection scope | Cancellation must reach owned work; cleanup may suspend but must finish before scope returns | Handler/producer faults before/after headers |
| Outgoing chunk/stream | Producer until submission; bounded engine queue after acceptance | Accepted writes cannot be retried; cancellation must release blocked producers | Slow-reader plateau and response timeout |
| WebSocket | Successful upgrade callback | Transport ownership transfers only on successful handoff; app closes after callback | Experimental: concurrent sends, timeout and cancellation campaign |
| DB pool/lease/transaction | Pool scope; lease callback owns temporary use | Borrowed DB resource must not escape; cancellation requires rollback and lease release | Real backend cancellation/rollback and exhausted pool |
| Session state | Memory store or SQL/cookie backend according to API | Backend-specific replay/revocation/rotation; no universal session-lock contract | Concurrent rotation, expiry and DB cancellation |
| Static file handle | Confined file helper | Scoped open/read/close; returned bytes belong to caller | Concurrent filesystem changes and interrupted reads |
| Partial upload | Confined upload helper/callback | Generated exclusive path; filename remains metadata; each completed file lives only through its callback; failed/cancelled partial upload removed | Disk exhaustion, cleanup I/O failure and cancellation interleavings |
| Observation sink | Caller-owned integration | Must not take transport ownership or log credentials; API remains P1 | Explicit exception/backpressure contract |

## Suspended callback cleanup

`test/adapter/lwt_test.ml` now suspends a handler finalizer behind a controlled gate
and triggers either a transport read failure or external cancellation. It requires
`with_connection` to remain pending and the transport to remain open until cleanup
is released, then requires exactly one close and the original failure/cancellation.
The transport-failure schedule is also checked under Eio's native scope model.

This exposed a Lwt defect: cancelling callback work started its finalizers, but
cleanup joined only reader/writer promises. `with_connection` now joins callback
work as well, before closing the transport. The fix affects teardown, not the
per-request parsing or write path. A slow finalizer now delays completion as the
ownership contract requires; detached or non-cancellable user work remains outside
what the adapter can force to terminate.

Remaining tests must cover SIGTERM idle/during parsing/handling/streaming, client
disconnect with blocked output, header/body/response deadlines, body overflow,
cancelled transactions/uploads/WebSockets and cleanup-error precedence. Existing
unit controls are useful evidence, not proof of every interleaving or release
approval. See [adapters](adapters.md) and [production roadmap](protocol-libraries-plan.md).

## Temporary upload callback scope

`test/web_eio/runtime_test.ml` checks that a completed file is readable during its
callback and removed before the next callback. This reproduced retention of earlier
parts until the entire request completed. `Files.with_upload` now performs protected
removal after each callback, while outer cleanup still owns any partial file or a
path whose earlier removal failed. Existing callback-exception and partial-upload
cancellation controls remain in the regression suite. Successful cleanup bounds
helper-owned temporary files to the current part; application-created durable
copies remain the application's responsibility. Disk exhaustion and cleanup-I/O
error precedence still need dedicated fault schedules.

Additional native controls wrap real confined filesystem operations to inject
ENOSPC during a write, a close error after descriptor retirement, and a first
unlink failure. All three propagate failure and remove the temporary file; the
unlink failure is retried by outer cleanup. Incomplete files never reach the
callback. A cancelled completed-file callback suspends its protected finalizer:
the file remains available until that finalizer finishes, no next part starts,
and removal finishes before connection EOF. These controls validate helper
ownership, not the behavior of a full disk or a filesystem that permanently
refuses deletion. Persistent cleanup failure and simultaneous-error precedence
remain explicit acceptance gaps; applications must observe cleanup I/O errors.

## Lwt application deadlines

A request deadline must not finish while its handler or response producer still
owns resources. The same rule applies to WebSocket callbacks and I/O. Controlled
clock tests in `test/extensions/lwt_app_test.ml` reproduced early transport closure
and error reporting while a cancelled finalizer was suspended. A shared private
Lwt deadline helper now races without automatically abandoning the losing branch,
then cancels and joins both branches while preserving the winning outcome. Tests
cover handler/stream deadlines, external server cancellation and WebSocket callback
timeout. These complement the lower-level transport cleanup controls above.

Finalizers that must survive cancellation should use `Lwt.no_cancel`; Eio cleanup
uses `Eio.Cancel.protect`. Cleanup must eventually finish: the deadline starts
cancellation but cannot safely impose a second hard cutoff on resource release.
The extra promise bookkeeping is outside the parser/encoder; its application-path
allocation cost remains part of the end-to-end profiling campaign. WebSocket
support remains experimental despite this specific lifecycle correction.
