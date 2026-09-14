# Production limits inventory

Inspection baseline `88c8ed5`; values are current constructor defaults, not a
validated aggregate production profile. P0-07 owns the complete units/defaults/
configuration audit. Do not replace them all with one global mutable config.

| Owner | Current defaults | Meaning / caveat |
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

`test/web/multipart_limits_test.ml` checks header, part, total and count limits
at exact/one-over boundaries, empty zero-byte parts and near-max_int header
configuration across segmentation schedules. Multipart's partial delimiter
allowance uses subtraction so a large configured header limit cannot wrap and
reject a fragmented request that succeeds in one chunk. Defaults are unchanged.

Memory-session clock and TTL inputs must produce a finite, strictly future expiry.
The pure store rejects addition overflow or rounding back to the current time
before entropy consumption/insertion; rotation restores the previous session on
failure. Native application wrappers retain their existing bounded TTL policy.
