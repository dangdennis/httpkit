# Streaming HTTP/HTTPS client

The experimental client supports streaming requests and responses in Eio and Lwt,
with optional bounded connection pools.
`httpkit-client` owns pure URL/request policy; `httpkit-client-eio` and
`httpkit-client-lwt` add native networking and upstream TLS. The core, HTTP/1
codec, engine and existing server packages acquire no TLS dependency.

Run the examples with an HTTP or HTTPS URL:

```sh
tools/dune-pkg exec -- examples/client/fetch_eio.exe https://www.rfc-editor.org/rfc/rfc9112.txt
tools/dune-pkg exec -- examples/client/fetch_lwt.exe https://www.rfc-editor.org/rfc/rfc9112.txt
```

Both write the response status to stderr and stream body bytes to stdout.
They initialize the upstream OS-backed RNG and obtain the system trust store
through `Ca_certs.authenticator`. Trust-store discovery happens once, before the
request deadline starts. The library requires an explicit authenticator; it has
no insecure default. Custom trust anchors belong to the application.

## API and ownership

```ocaml
Httpkit_client_eio.with_response
  ~net:(Eio.Stdenv.net env)
  ~clock:(Eio.Stdenv.mono_clock env)
  ~authenticator url
  (fun response body ->
    let rec copy () =
      match Httpkit_client_eio.read body with
      | None -> ()
      | Some bytes ->
          Eio.Flow.copy_string bytes (Eio.Stdenv.stdout env);
          copy ()
    in
    copy ())
```

Lwt exposes the same shape with native promises and no Eio arguments. See the
[executable Lwt example](../examples/client/fetch_lwt.ml). `read` yields a bounded
chunk or `None` after complete framing; `trailers` is available afterward,
including an empty collection. Only one read may be active at a time. A body
cannot be read after its callback returns. Callbacks must join any work they
start, cooperate with cancellation and keep their finalizers finite.

`with_response` owns one connection and closes it on completion, early callback
return, exception or cancellation. Unread bodies are abandoned, never drained for
reuse. Final statuses, including redirects and errors, are returned unchanged.
There is no automatic redirect, HTTP retry, cookie jar, proxy discovery,
decompression or protocol handoff. Connection establishment may try multiple
resolved addresses; HTTP requests and upload producers are never replayed.

## Streaming uploads

Pass `~meth:Httpkit_core.Method.post` (or PUT/PATCH/DELETE/OPTIONS) and an `~upload`.
GET remains the default; HEAD is supported without an upload. CONNECT, TRACE and
extension methods are rejected. The client owns Content-Length/Transfer-Encoding;
callers cannot inject either header.

```ocaml
let sent = ref false in
let upload = Httpkit_client_eio.upload ~length:3L (fun () ->
  if !sent then None else (sent := true; Some "abc")) in
Httpkit_client_eio.with_response ~net ~clock ~authenticator
  ~meth:Httpkit_core.Method.post ~upload url consume_response
```

An upload is single-use, including after failure. With `~length`, it must produce
exactly that many bytes; otherwise the client uses chunked framing. Each chunk
must contain 1–65536 bytes. Backpressure delays the next producer call. The
producer runs only after TLS authentication, concurrently with response receipt.
An early final response cancels and joins it before invoking the response callback;
a partially sent upload prevents connection reuse. Producer failures, length
mismatches and cancellation close the connection. Bytes already sent cannot be
recalled. Application producers and finalizers must cooperate with cancellation.

The file examples send a chunked PUT with bounded 32KiB reads:

```sh
tools/dune-pkg exec -- examples/client/upload_eio.exe URL FILE
tools/dune-pkg exec -- examples/client/upload_lwt.exe URL FILE
```

## Bounded origin pools

```ocaml
Httpkit_client_eio.with_pool ~net ~clock ~authenticator
  ~max_connections:4 "https://example.org" (fun pool ->
    Httpkit_client_eio.request pool "https://example.org/a" consume_response;
    Httpkit_client_eio.request pool "https://example.org/b" consume_response)
```

Lwt has the same operations with native promises. Pools accept only the same
scheme, case-insensitive hostname and effective port. The authenticator, parser
limits and adapter policy belong to the pool. All operations must stay in the
same Eio domain or Lwt event loop.

The default cap is four connections (configurable from 1 to 1024). Requests above
the simultaneous cap fail with `Pool_exhausted`; no unbounded waiting queue is
created. There is no pipelining. Reuse requires reading through `None`, validated
HTTP completion, drained outgoing bytes, and empty adapter staging. Abandonment,
callback failure, cancellation and `Connection: close` retire the connection.
Each exchange gets a fresh engine; adapters cancel and join their I/O work before
releasing a transport into the pool. There are no idle I/O workers.

Idle connections expire after 30 seconds by default, **checked on the next borrow**;
there is no background eviction timer. Scope exit closes all idle connections and
cancels and joins active requests, including their finalizers. A pool cannot be
used after its scope exits. A peer can close an idle connection at any time; the
next request fails without automatic retry. Handle any retry at the application
layer with explicit knowledge of whether replay is safe.

## Limits and TLS policy

The default total deadline is 30 seconds, covering DNS, connection establishment,
TLS, headers, streaming and the callback. `?timeout` changes it; `?policy` and
`?limits` retain the existing adapter/codec controls. DNS/native blocking work
and user callbacks are subject to the runtime's cancellation capabilities.
Cleanup is joined. TLS teardown attempts a closure alert with a separate maximum
one-second allowance, then closes the underlying transport even if alert output
fails. Arbitrary application finalizers can take longer.

URLs are limited to 8192 bytes. Only absolute HTTP/HTTPS URLs are accepted;
userinfo, fragments, raw whitespace/control/non-ASCII bytes, backslashes and
encoded authorities are rejected. Path/query escapes remain encoded. The client
sets Host and controls connection persistence; callers cannot override framing or connection
control fields. URL validation is not an SSRF policy: applications accepting
untrusted URLs must enforce destination and network-access restrictions.

HTTPS authenticates the URL DNS name or IP address and offers only HTTP/1.1
via ALPN. The upstream TLS library continues to own cryptography, record parsing
and authenticated closure. A thin raw-I/O guard turns TCP EOF into
`Httpkit_client.Tls_truncated` before the TLS adapter can normalize it into EOF.
The Eio adapter uses a guarded flow; Lwt uses guarded channels with explicit
output flush and scoped channel cleanup. A verified TLS `close_notify` retains
the upstream clean-EOF result.

Consequently, close-delimited HTTPS completes only after authenticated closure.
Abrupt EOF, including a cut TLS record, fails instead of returning `None` (wrapped
in the transport error during response reads). Previously delivered chunks cannot
be retracted: applications must treat an eventual read failure as an incomplete
transfer. Fixed-length/chunked responses complete at their HTTP framing boundary;
they need not wait for TLS closure. Plain HTTP retains normal close-delimited
behavior. See [RFC 9112 §9.8](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.8).
The earlier pure `check_response` helper remains conservative for other transports;
the native clients no longer use it.

No response body is accumulated by the library. The default codec step bounds
chunks to 16KiB; adapters and TLS add their own buffering. Application-retained chunks,
DNS results, trust anchors and concurrent calls are outside that byte bound.
This is not a measured aggregate-memory or sustained-load guarantee.

## Feedback loop and evidence

Run `tools/client-check _artifacts/client-feedback/<name>` after client changes.
It forces policy, network cancellation, HTTP/TLS lifecycle, upload, pooling,
concurrency, engine and adapter tests; then runs uninstrumented measurements.
Each run records matching source fingerprints, latency distributions, allocated
bytes per request, post-GC retained heap, descriptor deltas, and OS time/RSS data.
Use `HTTPKIT_CLIENT_ITERATIONS=200` for a longer repeatable run.

Measurements include the local fixture server and runtime setup; they are not
isolated client throughput. Fetch samples transfer 200KB. Pool samples perform
100 exchanges on one connection. Resource samples perform 16 × 256KiB responses
through four connections with slow consumers. Tests require exact connection and
closure counts, bounded response chunks, zero descriptor growth and less than
1MiB retained growth after warmup. Fetch allocation tripwires allow 2MB/request
for HTTP and 7.3MB for HTTPS in this combined fixture. Timing is advisory because
host scheduling and local DNS add noise. RSS is recorded, not an aggregate-memory
proof. Measurement children have watchdogs; instrumentation/GC overrides are
rejected. Baselines and failures stay under ignored `_artifacts/client-feedback`.

Security controls include certificate/hostname rejection, authenticated versus
abrupt TLS EOF, scoped body/pool ownership, single-use producers, owned framing,
length mismatch, early-final cancellation, address fallback, DNS/connect deadlines,
parent cancellation, connection caps, origin isolation, expiry, abandoned bodies,
and pool exit while a callback finalizer is suspended. Separate installed native
and bytecode consumers exercise the expanded surface and opposite-runtime isolation.
`tools/dev validate` remains the integration gate.

The API review is explicitly deferred. These local controls and bounded campaigns
do not establish production readiness or replace long fuzz/load campaigns and
independent security review. See [the feedback plan](client-work-plan.md).
