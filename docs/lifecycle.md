# Lifecycle and ownership

Each resource has one owner and an explicit retirement point. Cancellation starts
cleanup; it does not justify abandoning an owned resource. Custom callbacks must
yield cooperatively and finalizers must terminate. See [status](status.md) for
validation outcomes and unresolved issues.

| Resource | Owner and retirement | Important boundary |
| --- | --- | --- |
| Listener/backlog | Caller of `serve` / `serve_connections` | Caller configures backlog and closes the listener; accepted transports transfer to workers |
| Connection | `with_connection`, or the successful handoff recipient | One domain/event loop; join callback, reader and writer before one close; primary failure survives cleanup failure |
| Engine/exchange | Connection driver | One mutable owner; connection-specific IDs; abort is idempotent |
| Request reader | Active application exchange | Single reader; cannot escape its documented scope |
| Handler/response producer | Application exchange | Cancellation reaches owned work; finalizers join before scope completion |
| Output | Producer before submission; engine after acceptance | Retry only backpressured commands; accepted bytes must not be submitted twice |
| WebSocket | Successful upgrade callback | Transfer transport and suffix together; upgraded callback owns close; support remains experimental |
| Database | Pool scope and temporary lease callback | No escaped/shared connection or nested transaction; rollback before release |
| Session | Selected memory, SQL or cookie backend | Replay, revocation and rotation differ by backend |
| Static file | Confined file helper | Scoped open/read/close; returned bytes belong to the application |
| Temporary upload | Confined helper and current callback | Generated exclusive path; filename is metadata; durable copies are application-owned |
| Observation sink | Application integration | Synchronous, bounded and nonblocking; no transport ownership; ordinary errors isolated |

## Cancellation and deadlines

Both native adapters join suspended callback finalizers before closing transport.
Lwt application deadlines also cancel and join the losing branch while preserving
the winning result. Protected cleanup uses `Lwt.no_cancel` or `Eio.Cancel.protect`.
A slow finalizer extends completion; a deadline cannot safely impose a second
hard cutoff by abandoning cleanup.

WebSocket closing reads and writes share the remaining absolute close budget.
A Ping and its Pong cannot restart that budget. Open-connection callback/I/O
budgets are separate. See [adapters](adapters.md) for transport deadlines and
[application limits](production-limits.md#application-deadline-configuration).

## Upload lifetime and failures

A completed temporary file is available through its callback and removed before
the next part's callback. On callback cancellation, protected cleanup completes
before deletion and connection closure. Partial files never reach the callback.
Outer cleanup can retry removal after an earlier failure.

Permanent filesystem errors remain visible and may leave a file requiring
application recovery. A pre-existing collision is never deleted as an owned
upload. Applications must observe cleanup errors and explicitly copy durable
content before the callback returns.

## Database shutdown

Closing a pool immediately rejects new borrowers and waits for active leases.
A cancelled transaction's finalizer retains its lease until it finishes; rollback
then completes before release. A separate connection is needed to verify that
uncommitted writes did not persist.

Interrupted close does not reopen admission. Retry close after the lease retires
or finish the owning switch. Closing a pool from its own lease callback would wait
for itself and is unsupported. A lost connection during COMMIT can leave the
outcome unknown; do not automatically replay the transaction.

## Accept racing with shutdown

Once `accept` returns a transport, the server owns its close even if admission
has stopped. That late transport does not enter the HTTP driver. Close is protected
and joined before `serve` returns. The caller's close operation must eventually
finish; a graceful HTTP deadline does not permit abandoning it.

## Regression entry points

- `test/adapter`: suspended finalizers, transport failures and cancellation.
- `test/extensions/lwt_app_test.ml`: handler/stream/WebSocket deadlines.
- `test/web_eio/runtime_test.ml`: per-part lifetime, I/O faults and upload cleanup.
- `test/db_eio/db_test.ml`: real SQLite/PostgreSQL leases, rollback and shutdown.
- `test/production/websocket_deadline_test.ml`: absolute closing budget.
- `test/production/late_accept_test.ml`: shutdown waits for late transport close.

These controls cover named schedules, not every OS/runtime fault combination.
[Testing](testing.md) describes broader validation and retained evidence.
