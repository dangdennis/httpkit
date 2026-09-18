# Production limits inventory

Inspection baseline `88c8ed5`; values are constructor defaults at that baseline, not a
validated aggregate production profile. Check the relevant constructor when
selecting limits for a new application; see [status](status.md) for validation.

| Owner | Baseline defaults | Meaning / caveat |
| --- | --- | --- |
| Core headers | 100 fields, 65536 field bytes | Persistent collection; caller can retain older versions |
| HTTP/1 codec | 8192 line, 32768 head, 100 fields | Byte counts; request/status lines share a limit |
| HTTP/1 trailers | 16384 bytes, 64 fields | Declared names only |
| HTTP/1 chunk/work | 1024 chunk line, 16384 per call | Bounds parsing step and emitted data |
| Codec body | No total quota unless supplied | Low-level streaming choice; not permission for unlimited application collection |
| Engine | 65536 queued output bytes | Does not include OCaml/native metadata/staging overhead |
| Timeout policy | Header 10s, body/write idle 30s, keep-alive 30s, graceful 10s | Body/write idle can explicitly be disabled; header deadline does not reset on progress |
| Eio/Lwt application | 16 connections, 1 MiB body, 32768 output, 60s request | Application limits differ from low-level defaults |
| JSON | 1 MiB, depth 64 | Parse helper; ownership of supplied input precedes parsing |
| URL/form primitives | 8192 bytes, 100 pair fields | App form collection passes a separate 1 MiB cap |
| Multipart | 8192 header bytes, 100 parts, 1 MiB/part, 8 MiB total | App body budget can bind earlier; feed <=64 KiB |
| WebSocket | 1 MiB frame, 4 MiB message; feed <=64 KiB | Reassembled complete events; experimental |
| Eio realtime | 30s idle timeout | Review all write/close/queue paths and Lwt parity separately |
| Eio static | 8 MiB file collection | HEAD also reads/hashes currently; no large-file optimization claim |
| Memory sessions | 1024 entries | Process-local; expiry/clock and concurrency contract need deployment review |
| DB | 8 connections, 32 waiters, 10s statement timeout | Native backend behavior and transaction cancellation need real DB controls |

Sources: `lib/core/headers.ml`, `lib/http1/httpkit_http1.ml`, `lib/engine`,
`lib/web_eio/app.ml`, `lib/web_lwt/app.ml`, `lib/web/{json,url,multipart,websocket,session}.ml`,
`lib/web_eio/{files,realtime}.ml`, `lib/db_eio/httpkit_db_eio.ml`.

Remaining inventory: kernel/listener backlog versus app admission, queued tasks,
response-producer retention, runtime-specific write/close budgets, SQL session
locks, per-process native allocations and aggregate per-connection/per-request
memory. Test zero/exact/one-over limits, overflow, cancellation and combinations.
A logical queue count is not a total-RSS guarantee. This document centralizes
review visibility without claiming all runtime limits have been reconciled.

## Admission and combined byte budgets

Both application servers use a fixed number of workers. A worker accepts one
transport and retains that slot through the HTTP exchange, protocol handoff,
callback cleanup and transport close. It then accepts again. There is no additional
application queue of already accepted connections. The listener's kernel backlog
and any queue implemented by the caller's `accept` callback are separate resources;
`max_connections` does not configure or bound them. Handlers that create their own
detached work also fall outside this admission bound.

`test/production/admission_test.ml` checks capacities one and three in both Eio
and Lwt. A blocked writer fails while the producer is backpressured. Its protected
cleanup is then suspended: no replacement is admitted and no close/error callback
runs until cleanup is released. Exactly one slot becomes available afterwards,
and cancelling the server closes every admitted transport once. This is a
deterministic ownership test, not a large-connection soak or an RSS measurement.

For the default 16 application connections, selected logical byte budgets add up
as follows. These terms describe different owners; they are not a total allocation
or resident-memory ceiling.

| Term | Per connection | At 16 connections |
| --- | --- | --- |
| Engine output queue | 32 KiB | 512 KiB |
| Adapter read buffer | 16 KiB | 256 KiB |
| Adapter retained input string | At most 16 KiB | At most 256 KiB |
| Pending engine body-data event at default codec step limit | At most 16 KiB | At most 256 KiB |
| Eio `of_flow` read scratch | 16 KiB | 256 KiB |
| Application body collection limit | 1 MiB of body content | 16 MiB of body content |

The body collector may temporarily hold both its accumulation buffer and returned
string. HTTP heads, parser buffers, queue nodes, runtime stacks, GC capacity, native
socket/DB buffers and write conversion temporaries add overhead. A handler may
retain older bodies or arbitrarily large response strings. `send` breaks output
into bounded queue chunks, but its caller still owns the complete supplied string
until the call returns. Producers should construct finite chunks rather than
first materializing an unbounded response. These application retention choices
must be part of any measured deployment budget.

These byte counts follow the current adapter read loops, `of_flow`, engine pending
event and output accounting. Custom codec limits/transports change the inventory.
Finite defaults and bounded admission are necessary evidence; an aggregate
production profile still requires long-running RSS/native-resource measurements
with representative handlers and database usage.

Memory-session clocks and TTLs must produce a finite, strictly future expiry.
Invalid expiry arithmetic is rejected before inserting a session; failed rotation
restores the previous session.

## Application deadline configuration

Both `Httpkit_eio.serve` and `Httpkit_lwt.serve` accept the same checked `~policy`
from `Httpkit_engine.Timeout.policy`. The default durations above are unchanged.
For example, an application may explicitly select:

```ocaml
let policy =
  Result.get_ok
    (Httpkit_engine.Timeout.policy
       ~header:5. ~body_idle:(Some 15.) ~write_idle:(Some 15.)
       ~keep_alive:15. ~graceful:10. ())
```

Pass `~policy` alongside the server's `~max_connections`, `~body_limit`,
`~output_limit` and `~request_timeout`. Header time is absolute once parsing starts;
body/write deadlines measure inactivity. The application request deadline covers
handler and producer work independently. Disabling a body/write idle deadline
does not disable the application deadline. Successful upgrades leave HTTP/1 and
need the WebSocket callback/I/O policy configured separately.

Controlled-clock tests in `test/production/timeouts_test.ml` exercise all five
phases through each public application server with a two-second custom duration,
checking timeout category and exactly one transport close. Eio can aggregate
simultaneous native shutdown exceptions; every contained error must still match
the expected phase. See [status](status.md) for completed stress campaigns and
remaining issues. Aggregate application memory acceptance remains open; exposing
these knobs does not establish a measured production budget.
