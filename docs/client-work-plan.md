# Client implementation and checks

Implemented for Eio and Lwt: scoped streaming responses, fixed/chunked uploads,
bounded same-origin pools, cancellation/cleanup, and authenticated close-delimited
HTTPS. API review remains deferred. Read [the client guide](client.md) for use and
[current status](status.md) for evidence and open issues.

## Run the feedback suite

```sh
tools/client-check _artifacts/client-feedback/new-run
HTTPKIT_CLIENT_ITERATIONS=2000 tools/client-check _artifacts/client-feedback/extended-run
```

Use a new directory for each attempt. The suite runs policy, HTTP/TLS lifecycle,
engine and adapter checks, then fetch/pool/slow-consumer measurements. It records
source fingerprints, allocation, retained heap and descriptor changes. Timings
include the local fixture server and runtime setup; they are not client-only
throughput. Run `tools/dev validate` for full integration and installed consumers.

## Contracts the tests preserve

- Uploads: exact framing/length, bounded chunks, producer failure/cancellation,
  early responses, joined cleanup and no replay. TLS authenticates before invoking
  the body producer.
- Pools: same-origin admission, finite capacity, no pipelining, reuse only after
  complete response/upload consumption, and discard on failure or abandonment.
- TLS EOF: verified `close_notify` completes a close-delimited body; raw EOF and
  cut records fail. Upstream TLS libraries own the cryptography.

These checks do not replace application-specific load or independent review.
