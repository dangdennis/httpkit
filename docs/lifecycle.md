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
| Partial upload | Confined upload helper/callback | Generated exclusive path; filename remains metadata; failed/cancelled upload removed | Disk exhaustion, partial cleanup and callback exceptions |
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
