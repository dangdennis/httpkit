# Client feedback and implementation gates

Scope: cancellation/cleanup, resource testing, streaming request
bodies, bounded origin-scoped pooling, and authenticated close-delimited HTTPS for
Eio and Lwt. The user corrected the scope: only API review is deferred.

Run `tools/client-check _artifacts/client-feedback/<slice>` after every slice.
It runs policy, real HTTP/TLS lifecycle, engine and adapter regressions, then
uninstrumented repeated local fetch measurements, recording source fingerprints.
`HTTPKIT_CLIENT_ITERATIONS=200` lengthens the measurement run. Measurements include
both client and fixture server plus runtime/connection setup, not isolated client
throughput. Compare same-machine repeated samples; do not gate on noisy absolute
wall times. Allocations, retained heap and exact resource counts are additional
signals. Final integration uses `tools/dev validate` and installed consumers.

Before accepting uploads: fixed/chunked framing, exact payload, slow receiver,
bounded producer chunks, length mismatch, producer failure/cancellation, early
final response, joined producer cleanup and no replay. Caller framing/connection
headers remain prohibited. Authenticate TLS before invoking a producer.

Before accepting pooling: exact same-origin admission, fixed maximum connections,
explicit overload, no pipelining, fully consumed response and drained upload before
reuse, discard on abandonment/error/cancellation/close, scoped teardown, escaped
pool rejection, and idle expiry. Never retry stale connections or replay uploads.
Pool credentials, TLS authenticator and parser limits belong to the pool scope.

Security controls are invariants, not a claim of comprehensive security review.
Short local performance/resource checks do not replace sustained load, independent
review, fuzz and release acceptance campaigns.

Before accepting close-delimited HTTPS: verified close_notify must complete; raw
EOF and cut records must fail, with upstream TLS still owning all cryptography.
