# Load and resource testing

Use these tools for endpoint profiling and adverse-client checks. For primitive
comparisons, see [benchmarks](benchmarks.md). Results and the unresolved
profiling hang are recorded in [status](status.md).

## End-to-end application endpoint profile

For stall investigation, add `--diagnostics`. This writes `workers.json` beside
the report every half second, recording worker phases and completed operations,
and marks the report `diagnostic_run: true`. Diagnostic timings are not acceptance
measurements. The sampler shares the load generator's runtime; an external
watchdog must capture process stacks if snapshots or completed epochs stop.
`processes.json` identifies the owned client, server, and loopback port for that
capture. Tracing does not change socket deadlines or response checks.

```sh
tools/dev endpoint-profile --seconds 10 --repetitions 3
# Explicit optimized server build, isolated from ordinary development builds:
tools/dev endpoint-profile --profile release --seconds 10 --repetitions 3
# Functional check of every endpoint/concurrency combination:
tools/dev endpoint-profile --seconds 0.1 --repetitions 1
# Approved beta capacity profile, opt-in; five samples per configuration:
tools/dev endpoint-profile --profile release --concurrencies 1,4,8,16,64 \
  --seconds 30 --repetitions 5
```

This local OCaml runner starts the Eio framework example with no database and
measures one endpoint at a time over persistent HTTP/1.1 connections. It retains
the example's routing, request IDs, security headers and CORS middleware. The
default binary uses the ordinary development build; `--profile release` builds
the same server in `_build-bench-5.5.0` with the release profile. The report records
the selected profile. Both builds and server launches clear inherited OCaml
tuning and instrumentation overrides using the same policy as microbenchmarks.
The already-running load client cannot have its startup runtime settings reset;
the report flags whether runtime-tuning variables were inherited. A supplied
`--binary` has external/unverified build provenance, cannot combine with an
explicit `--profile`, and must
expose the same Eio/compiler/counter contract. This is an application workload,
not a minimal codec or release-optimized framework comparison.

| Endpoint | Request body | Response body / producer chunks |
| --- | --- | --- |
| GET /plaintext | Empty | 14-byte greeting |
| GET /json | Empty | 27-byte JSON object, encoded per request |
| POST /echo | 4096 bytes | Exact 4096-byte echo |
| GET /small-stream | Empty | 4096 bytes in four 1024-byte sends |
| GET /large-stream | Empty | 1 MiB in 128 8192-byte sends |

The default configurations use concurrency 1, 4 and 8. `--concurrencies` accepts
distinct integers in 1..64; the beta profile uses1,4,8,16,64. Each gets one second of untimed warm-up,
then the requested repetitions. Payload contents and status are checked on every
operation. The report under `_artifacts/framework/endpoints-*/report.json` records
source, binary and workload hashes; lock metadata hash (full lock files also enter
the source hash); compiler, OS/architecture and available domains; throughput;
p50/p95/p99 histogram upper bounds; server allocated words/bytes per request,
minor/major collection counts and CPU time/utilization; RSS, descriptor and
connection observations; and final shutdown accounting. CPU utilization is a
percentage of one core. Allocated words are `minor_words + major_words - promoted_words`,
not an allocation-object count. Counter validation rejects decreases, invalid
word size and nonfinite values.

The runner sets the example's `HTTPKIT_MAX_CONNECTIONS` to at least 16 and the
largest selected concurrency, and verifies the server reports that exact setting.
Library and ordinary example defaults remain 16. The example accepts explicit
connection limits in 1..1024 and uses a listen backlog of at least 32 or that limit;
the backlog is separate from admitted application scopes. Profiles above 16 use
the approved512 MiB RSS ceiling; smaller profiles retain256 MiB. Both retain existing
descriptor, live-heap and warmed RSS growth checks. Per-worker completed operation
counts must all be positive, preventing a short run from silently measuring fewer
workers than requested. The report records both configuration and these counts.

These measurements establish successful concurrent endpoint traffic. They do not
by themselves establish simultaneous admission at capacity, continuous peak RSS,
slow-client safety, or overload behavior; the dedicated capacity campaigns cover
those boundaries separately.

The test-only `/bench-stats` endpoint samples process counters without forcing GC.
Counter intervals include boundary requests and connection setup/teardown, so
allocation results have a small sampling overhead. Resource checks force GC only
outside those intervals. The client and server share a host; client byte checking,
thread scheduling, laptop load and GC can limit throughput. A short run is a
functional check, not a statistical baseline. No automatic timing threshold is
introduced. Stable baselines, Lwt parity, separate load hosts and external framework
comparisons remain in the [measurement backlog](benchmark-todos.md).

The developer load client retains at most 8 KiB of read-ahead per connection.
It preserves surplus response bytes across parser calls; a socket-pair control
checks consecutive fixed/chunked responses and EOF. An injected read failure
also checks that a retry cannot replay previously consumed buffer contents. Endpoint reports include
`persistent_client_read_calls` and the per-operation ratio, so client syscall
cost is visible alongside server counters. Source/workload
identity must be checked when comparing historical reports: changing the load
client can change measured throughput without changing httpkit's server code.

## Admission and TCP backlog controls

`tools/dev capacity-stress` runs one cycle at each of1,16,64 application slots.
Use `--capacities 1,64` to select capacities, or `--seconds 60` to repeat cycles
for at least 60 seconds **per capacity**, finishing the last cycle. The maximum is
3600 seconds per capacity; zero means one cycle. This is local validation, with
no hosted CI dependency.

Each cycle fills every application slot with a confirmed keep-alive request,
then makes enough concurrent TCP attempts to reach128 total attempts. TCP may
connect into the kernel backlog without acquiring an application slot. The runner
requires no additional HTTP response or transport admission while all slots are
held, then closes one held connection and requires exactly one queued request to
complete within 5 seconds. It records established, refused, reset and timed-out
attempts separately; it does not call kernel queuing an application rejection.
Connect attempts have a750 ms deadline. Timing is a generous liveness control,
not a throughput or latency baseline.

One server remains alive for all cycles at a capacity. Statistics are sampled
over a held connection during saturation, avoiding an extra admission slot.
The runner checks512 MiB sampled RSS, connection accounting, admitted descriptor
bounds, idle descriptor return within 2 of baseline, and the existing warmed
32 MiB RSS/1 MiB live-heap growth controls. Shutdown requires every admitted
connection closed and zero unexpected errors. All started client workers are
joined and their sockets closed on failure too.

Reports under `_artifacts/framework/capacity-*/` retain per-cycle observations,
source/binary identities, platform, capacity, timing and final cleanup counts.
The development-profile server clears inherited instrumentation/runtime tuning;
the report flags inherited load-client tuning. RSS is sampled, not a continuous
peak measurement. A one-cycle smoke cannot establish warmed memory stability.
These controls cover admission, idle keep-alive and backlog handoff. Slow headers,
stalled/unread bodies, blocked readers, disconnect and shutdown stress at all
capacities and the final frozen-candidate campaigns remain separate requirements.
`PASS` here never marks a release ready.

## Incomplete input, disconnect and shutdown controls

`tools/dev slow-client` exercises1/16/64 confirmed admitted connections with
partial headers, trickled header bytes, stalled bodies, client reset mid-body and
SIGTERM with incomplete bodies. Select a subset with `--capacities 1,64` and
`--scenarios header,drip-header,body,disconnect-body,shutdown-body`. Shutdown runs
last because it consumes the server. All selected scenarios at a capacity share
one server; the next capacity gets a fresh process.

The runner uses unchanged production defaults:10 s absolute header and 30 s body-idle
deadlines. The trickle sends one byte per sample (roughly each second) for the
first 8 s and requires at least 5 drips, demonstrating that progress cannot slide
the header deadline. Closure must occur within the deadline plus 5 s scheduling
tolerance; response/closure earlier than2 s before expiry is rejected. These are
real-socket timing controls, complementing deterministic mock-clock phase tests.
SIGTERM allows the existing 15 s process-exit bound; every client then observes
closure. Reset/shutdown begin after incomplete input has been sent on confirmed
connections; this runner does not instrument handler entry.

Reports in `_artifacts/framework/slow-client-*/` record per-connection closure
times, bounded response-byte counts, process RSS/descriptor samples, drained
accounting and final zero-live-connection shutdown. Per-scenario sample files
remain available on failure. Sampling needs no additional HTTP connection while
every slot is occupied. Server runtime tuning/instrumentation is cleared; inherited
load-client overrides are reported. Source and binary changes invalidate the run.
This is development-profile functional evidence, not sustained-memory acceptance,
blocked-reader proof or a production-ready claim. Unread-body reuse and blocked output have dedicated tools below; sustained acceptance remains separate.

## Observed blocked output

`tools/dev backpressure` uses a dedicated local fixture at 1/16/64 connections.
Select `--capacities 1,64` or `--scenarios resume,reset,timeout,shutdown` for a
subset. Application and transport defaults stay unchanged. The fixture streams
8 MiB using one reused8 KiB chunk; clients initially advertise small receive buffers
and do not read responses.

Every connection must have an active producer waiting in send, a nonempty output
queue bounded by 32768 bytes, and stable produced-byte and successful transport-write
counts across a one-second interval. A stream fitting into the kernel buffer cannot
satisfy this test. A bounded atomic snapshot file provides observations without
requiring another application connection during saturation. The fixture retains
current connection state, aggregate counters and at most one capacity's worth of
recent closure timings, not an unbounded event history.

The runner resumes reading and checks the entire stream in bounded chunks plus
keep-alive reuse; resets clients and requires producer cleanup; waits for the
default 30 s **write** idle timeout with5 s scheduling tolerance; or sends SIGTERM while
producers are blocked. Idle/application timeout does not qualify as a write timeout.
Idle time is measured from each connection's last successful transport write:
kernel progress after an initial stall legitimately restarts that deadline. The
write-timeout scenario also has a55 s outer bound. Shutdown must finish within the
existing 15 s process bound. Workers are joined
before client sockets are retired on failure.

Reports under `_artifacts/framework/backpressure-*/` retain blocked-state snapshots,
sampled RSS/descriptors, failure categories, producer completion/failure counts,
drained resource checks and final accounting. These are development-profile
functional controls on a shared host, not continuous peak RSS, production
throughput or sustained acceptance evidence. Source/binary identities remain
attached. The fixture adds no production endpoint or runtime dependency.

## Unread bodies and reuse

The engine's existing strict policy is to abort an unfinished upload when the
application sends a final response, then close after output. It does not drain an
unread body to reuse the connection. A handler that wants keep-alive reuse should
consume the body to completion before returning; those reads validate framing,
trailers and the application quota and remain inside the application deadline.

`tools/dev unread-body` checks this distinction at 1/16/64 connections. Ignored
fixed/chunked bodies, malformed unread chunks and stalled uploads must receive the
early response and close promptly, without dispatching a following request. Fully
consumed fixed/chunked bodies with valid trailers must echo the exact body and
permit a subsequent pipelined request. A request-shaped string inside the body
must remain body data. Consumed malformed framing must close with a protocol
failure and no following dispatch. Select cases using `--scenarios`; reports are
under `_artifacts/framework/unread-body-*/`.

The shared fixture uses the same capacity/resource/cleanup checks as backpressure
controls. These short tests complement 66 segmented Eio/Lwt controls for ignored
versus consumed bodies, partial reads, quotas, trailers and application timeout
with body-idle timeout disabled. No new draining policy or production behavior
is introduced. Long frozen-candidate acceptance remains separate.

## WebSocket segmented-input allocation control

`test/web/websocket_buffer_test.ml` measures cumulative GC allocation, excluding
fixture construction, for complete, fragmented, one-byte and coalesced inputs.
Fourfold input growth must stay below a deliberately broad eightfold allocation
bound (plus 100 KB). This detects algorithmic copying without timing thresholds.

The initial native 5.5.0 run measured 4 KiB/16 KiB byte-by-byte frames at 8.68 MB/135.40 MB
allocated (15.59x), and 1024/4096 coalesced empty Ping frames at 3.31 MB/50.99 MB
(15.40x). Appending to a buffer, parsing with a cursor and compacting once after
consumed frames reduced those pairs to 0.55 MB/2.21 MB (3.99x) and 0.20 MB/0.79 MB
(3.98x). Values are decimal bytes allocated, not RSS, retained heap or end-to-end
throughput. Error/close resets release expanded buffers; ordinary open connections
may retain bounded buffer capacity for reuse. WebSocket remains experimental.
