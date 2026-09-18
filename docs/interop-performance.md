# Interoperability and performance evidence

The interop runner exercises six loopback lanes: Eio and Lwt directly, then each through Nginx with request/response buffering enabled and disabled. Nginx 1.30.4 is built from a checksum-pinned official source archive by `mise run setup:nginx`, entirely inside `.toolchain`. It runs under a temporary prefix and is stopped after each lane. No system service or privileged port is installed.

Independent clients are an OCaml client checked against the independent http/af parser and the host's curl, whose versions are recorded. Each lane exercises persistent GET, fixed and chunked POST, HEAD followed by another request, duplicate Set-Cookie preservation, and two ordered pipelined responses. Six malformed framing inputs each precede a marker request: CL+TE, duplicate CL, signed CL, unsupported TE chain, folded fields and invalid chunks. A malformed input must not reach the handler or allow its marker to reach the application.

TCP half-close is a separate observed policy test. Direct subjects complete their response after peer write-half-close. Nginx may cancel its upstream when it observes client abort; the report classifies that result instead of confusing it with ordinary pipeline corruption. Both buffering modes are explicit because buffering affects when the upstream sees bytes. [Nginx proxy module documentation](https://nginx.org/en/docs/http/ngx_http_proxy_module.html).

`tools/devlib/performance.ml` runs five independent uninstrumented engine sessions over 64 KiB, 1 MiB and 16 MiB bodies. Each execution verifies exact acknowledgement counts and a hard 32 KiB engine output queue bound while writes accept only 997 bytes at a time. Reports include allocation totals and post-major live words. These are payload/heap observations, not a claim that total process RSS equals queue capacity.

A seeded native socket workload then runs 200 requests per adapter at concurrency four, mixing fixed/chunked bodies of 0, 17, 4096 and 262144 bytes. Every response is checked; reports include p50/p99 end-to-end latency, transferred bytes, elapsed time and sampled process RSS. Applications retain at most one generated request body per worker in this workload. Runtime heaps, socket buffers, and application retention are distinct from engine queue accounting.

Timing is advisory. Same-source repetitions report noise; they are not a paired before/after baseline. No reserved, calibrated performance runner exists yet, so the release performance gate remains `NOT_READY`. This smoke workload also does not satisfy the planned two-hour soak. Nginx is one intermediary: Caddy ingress, forwarded identity, additional proxies and a broader differential corpus remain release-review scope.

Run:

```sh
mise run setup:nginx
mise run interop
mise run performance
tools/harness readiness --milestone M6
```

M6 readiness requires source-matched M5 evidence, the OCaml 5.5.0 interop report and a performance report with passing hard bounds. It establishes these implemented lanes and explicitly reports baseline limitations; it does not assert full release readiness. Retain `_artifacts` with the source identity; hosted CI is outside the current workflow.
