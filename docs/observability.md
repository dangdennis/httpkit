# Application observations

Both `Httpkit_eio.serve` and `Httpkit_lwt.serve` accept an optional
`~observe:Httpkit.Observation.sink`. The event types live in the runtime-neutral
`httpkit` package; neither runtime nor a telemetry vendor is required to consume
them. Leaving the option unset creates no events or transport-counting wrappers.

The initial events cover connection ownership:

- `Connection_accepted`: the caller's `accept` returned a transport, with a
  connection identifier and the active scope count.
- `Connection_closed`: the worker's connection scope finished, with identifier,
  active scope count, optional duration, completed read/write byte counts and
  explicit close outcome. It follows callback cleanup, close and error reporting.
- `Shutdown_started`: the explicit graceful-stop signal was observed, with the
  current active scope count. External cancellation is a different operation.

For example, either application's `serve` call can use this sink:

```ocaml
let active_connections = ref 0

let observe = function
  | Httpkit.Observation.Connection_accepted event ->
      active_connections := event.active_connections
  | Httpkit.Observation.Connection_closed event ->
      active_connections := event.active_connections
  | Httpkit.Observation.Shutdown_started _ -> ()
  | _ -> ()
```

Identifiers are local to a single `serve` invocation. Counts include upgraded
connections until their callbacks and close complete. A failed close is reported
as `Close_failed`, not successful resource retirement. Duration includes cleanup
and the application's error callback; an unavailable, non-finite or backwards
measurement is `None`. Byte counts include HTTP framing and upgraded traffic;
only valid successful transport-return prefixes are counted, saturating at
`Int64.max_int`. A failed write that consumed an unknown prefix cannot be measured.
These counters do not prove that a peer received or processed those bytes.

Events carry no addresses, request targets, headers, authorization values,
cookies, bodies or exception text. They can feed application-owned structured
logs, gauges and counters without parsing sensitive request data. Run the sink
synchronously, keep it bounded and nonblocking, and do not yield or launch
detached work. Ordinary sink exceptions are isolated; runtime cancellation still
propagates and joins owned cleanup. A cancellation during the acceptance event
also closes the accepted transport, before it has reached the normal driver.
There is no internal telemetry queue. A custom asynchronous exporter must provide
its own bounded queue and lifecycle.

`test/production/observation_test.ml` exercises partial reads/writes, upgrades,
invalid write counts, I/O and close failures, ordinary sink exceptions and sink
cancellation in both runtimes. The admission suite also runs with observations
enabled and disabled, checking bounded active counts through suspended cleanup.

## Request and callback scopes

Each validated request head produces `Request_started`. Its identifier is an
engine exchange number local to the connection, not a header supplied by a client.
`Callback_finished` measures the handler or streaming producer through its
finalizers, with an optional failure category. It excludes subsequent error
recovery. HEAD does not execute the producer, so it has no stream callback event.
A handler failure recovered by the application can produce a handler-error event,
an enqueued 500 status and a successful request scope.

`Response_headers_enqueued` records an accepted final response head and status;
it excludes interim 1xx responses. `Request_finished` measures the application
scope, including its deadline/cancellation cleanup. Its outcome is one of:

- `Response_enqueued`: response production and framing completed, and any
  needed request-body discard command was submitted.
- `Upgraded`: the HTTP scope handed off the transport; the upgraded callback
  continues in the connection scope.
- `Failed category`: an exception left the request scope.

Neither successful enqueue event means local output has drained or the peer has
received it. A blocked-writer control verifies request completion can be observed
before any successful write, so instrumentation does not insert extra flushes.

`Connection_failed` reports the first failure entering connection or shutdown
error handling. Header and idle timeouts can occur before a request exists.
Categories cover application and all five transport timeout phases, cancellation,
resource limits, protocol/transport errors, EOF, application errors and mixed
aggregated failures. Resource-limit events do not identify a specific quota.
The callback cancelled by a deadline may report `Cancelled`; the surrounding
request reports the application timeout after that callback's cleanup joins.
No exception messages or request contents are included.

The production observation tests cover recovery, streams, application deadlines,
every transport timeout phase, identity matching and enqueue-versus-drain behavior.
Queue depth, dedicated rejection/WebSocket events, richer shutdown progress and
enabled-hook allocation budgets remain separate work. These events establish no
production-readiness or peer-delivery claim.
