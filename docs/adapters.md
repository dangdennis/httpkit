# Native runtime adapters

M5 adds independently installable `http-kit-eio` and `http-kit-lwt`. Their APIs use native fibers/promises; core, codec and engine still have no runtime dependency. Eio depends on Eio 1.5, Lwt on Lwt 6.1.2, through both committed Dune locks. A legitimate Eio dependency named `lwt-dllist` is a data structure, not the Lwt promise runtime.

## Ownership and operation

`with_connection` owns the transport until its callback returns. It runs one reader and one writer, flushes accepted output on normal return, cancels and joins children, then closes once. An application exception aborts queued output and closes; an I/O error cannot turn into a successful flush merely because abort emptied the queue. Primary failures survive close failures. Runtime cancellation remains cancellation. Custom transport operations must be cancellation-aware.

Eio flows use bounded scratch buffers; Lwt descriptors use unbuffered reads and partial `write_string`. No hidden buffered channel is inserted. Each driver has a 16 KiB read buffer and at most 16 KiB immutable staging; Eio's flow wrapper adds 16 KiB scratch plus a bounded temporary write copy. Engine and codec retention are additional. Application-held bodies and runtime/socket buffers are outside these counts. `send` accepts an application-owned string and copies bounded chunks; applications producing large bodies should call it incrementally.

One domain/event loop owns a connection. One consumer owns `next_event`/`collect_body`. Request IDs remain connection-specific. `collect_body` defaults to 1 MiB and checks its bound before appending; crossing it aborts. `send` awaits output capacity, and `finish` closes framing. A CONNECT/Upgrade response that commits a tunnel already ends HTTP output: do not call `finish` afterward. After the Handoff event, `take_handoff` returns the transport and unconsumed staging suffix. Ownership transfers only on successful callback return; an unclaimed handoff or failed callback closes normally.

`serve_connections` uses a fixed number of scoped workers (1024 default). Each worker admits one transport at a time; accepted sockets and blocked handlers cannot grow beyond that number. The caller owns the listener, backlog, TLS and routing. Connection errors reach mandatory `on_error` after cleanup. Accept or error-handler failure stops all workers. Cancellation joins them; there are no detached tasks.

## Deadlines

The engine's `Timeout` module is pure; runtimes supply monotonic time and sleep. Defaults are absolute 10-second header completion, 30-second keep-alive, 30-second body/write idle, and 10-second graceful shutdown. Only body/write idle can explicitly be disabled. Durations must be positive and finite. Body deadlines pause while the application blocks input; header byte trickles never extend the header deadline. `shutdown` stops admission and waits under its deadline; the application must still complete any active exchange.

At equal-time readiness and expiry, the native runtime may choose either completion or timeout. Cleanup remains exactly once. Deterministic tests control the order. These deadlines protect active I/O, not arbitrary user code; a callback that blocks forever on unrelated application work requires an enclosing application deadline/cancellation scope.

## Evidence and limits

The adapter tests run under parent-process watchdogs. They cover byte-fragmented reads, partial writes, failed/zero writes, successful-flush error races, handler failures, blocked-read cancellation, 100 blocked-write/output-admission cancellation schedules per adapter, bounded body collection, admission cleanup, absolute headers, residual handoff and 200 KB real socket streaming. Lwt tests inject controlled timers and check pending timer/read cancellation; Eio uses its mock monotonic clock. Pure deadline tests check boundary equality and invalid policies.

Installed-package tests copy only the declared runtime closure, compile and execute bytecode/native examples, and prove the opposite runtime is unavailable. The exact same `examples/runtime/transform.ml` is used by both. `@doc` builds package documentation with odoc 3.2.1 and fatal warnings.

The broader plan still calls for reset/half-close permutations, fault coverage measurements, long stress campaigns, interop and independent security review. These tests establish the implemented adapter boundary; they do not certify the complete release plan.

## Configuring connection admission

Both `serve_connections` helpers accept `?limits`, `?output_limit` and
`?informational_limit`, with the same defaults as `Engine.server`. Invalid
settings fail before accepting a transport. Each accepted transport receives a
fresh engine; settings do not share queues or request identity between clients.
`failure_to_string` preserves the error category and transport exception detail.
Transport-provided text should only be logged where the application intends it.
