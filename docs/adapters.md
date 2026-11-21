# Native runtime adapter

The entry module is `Httpkit_transport_eio`.
Application handlers and dispatch live in `Httpkit_eio` (`httpkit-eio`); see the
[framework guide](framework.md).

The independently installable adapter is `httpkit-transport-eio`. Its API uses native fibers and promises; core, codec and engine still have no runtime dependency. The adapter depends on Eio 1.5 through both committed Dune locks. Eio is the only supported runtime. The `lwt-dllist` package that remains in the locks is a data structure required by Eio, not the Lwt promise runtime.

## Ownership and operation

`with_connection` owns the transport until its callback returns. It runs one reader and one writer, flushes accepted output on normal return, cancels and joins children, then closes once. An application exception aborts queued output and closes; an I/O error cannot turn into a successful flush merely because abort emptied the queue. Primary failures survive close failures. Runtime cancellation remains cancellation. Custom transport operations must be cancellation-aware.

Eio flows use bounded scratch buffers. No hidden buffered channel is inserted. Each driver has a 16 KiB read buffer and at most 16 KiB immutable staging; Eio's flow wrapper adds 16 KiB scratch plus a bounded temporary write copy. Engine and codec retention are additional. Application-held bodies and runtime/socket buffers are outside these counts. `send` accepts an application-owned string and copies bounded chunks; applications producing large bodies should call it incrementally.

One domain owns a connection. One consumer owns `next_event`/`collect_body`. Request IDs remain connection-specific. `collect_body` defaults to 1 MiB and checks its bound before appending; crossing it aborts. `send` awaits output capacity, and `finish` closes framing. A CONNECT/Upgrade response that commits a tunnel already ends HTTP output: do not call `finish` afterward. After the Handoff event, `take_handoff` returns the transport and unconsumed staging suffix. Ownership transfers only on successful callback return; an unclaimed handoff or failed callback closes normally.

`serve_connections` uses a fixed number of scoped workers (1024 default). Each worker admits one transport at a time; accepted sockets and blocked handlers cannot grow beyond that number. The caller owns the listener, backlog, TLS and routing. Connection errors reach mandatory `on_error` after cleanup. Accept or error-handler failure stops all workers. Cancellation joins them; there are no detached tasks.

## Deadlines

The engine's `Timeout` module is pure; runtimes supply monotonic time and sleep. Defaults are absolute 10-second header completion, 30-second keep-alive, 30-second body/write idle, and 10-second graceful shutdown. Only body/write idle can explicitly be disabled. Durations must be positive and finite. Body deadlines pause while the application blocks input; header byte trickles never extend the header deadline. `shutdown` stops admission and waits under its deadline; the application must still complete any active exchange.

At equal-time readiness and expiry, the native runtime may choose either completion or timeout. Cleanup remains exactly once. Deterministic tests control the order. These deadlines protect active I/O, not arbitrary user code; a callback that blocks forever on unrelated application work requires an enclosing application deadline/cancellation scope.

## Evidence and limits

The adapter tests run under parent-process watchdogs. They cover byte-fragmented reads, partial writes, failed/zero writes, successful-flush error races, handler failures, blocked-read cancellation, 100 blocked-write/output-admission cancellation schedules, bounded body collection, admission cleanup, absolute headers, residual handoff and 200 KB real socket streaming. Timing tests use Eio's mock monotonic clock. Pure deadline tests check boundary equality and invalid policies.

Installed-package tests copy only the declared runtime closure, then compile and execute bytecode/native examples. The pure handler in `examples/runtime/transform.ml` has no runtime dependency. `@doc` builds package documentation with odoc 3.2.1 and fatal warnings.

See [testing](testing.md) for broader fault, stress and interop checks and [status](status.md) for completed campaigns. Adapter regressions do not certify release readiness.

Client handoff controls suspend request-header writes across informational and
Upgrade/CONNECT response headers. The adapter preserves the exact binary suffix,
waits for full or partial writes to finish, rejects a second handoff claim, and
closes once on unclaimed handoff, callback failure after claiming, or callback
failure while the write remains suspended. Claimed successful handoffs transfer
close ownership. Failed CONNECT responses deliver normal HTTP bodies; segmented
premature EOF fails and closes. These controls do not cover every cancellation
or TLS handshake schedule.

## Configuring connection admission

`serve_connections` accepts `?limits`, `?output_limit` and
`?informational_limit`, with the same defaults as `Engine.server`. Invalid
settings fail before accepting a transport. Each accepted transport receives a
fresh engine; settings do not share queues or request identity between clients.
`failure_to_string` preserves the error category and transport exception detail.
Transport-provided text should only be logged where the application intends it.

Suspended callback finalizers are part of connection ownership: after failure or
cancellation, the adapter waits for their completion before closing the transport.
See the [lifecycle matrix and regression](lifecycle.md). Custom finalizers must
terminate; cancelling a promise alone does not establish that cleanup has joined.
