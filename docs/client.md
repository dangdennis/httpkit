# Streaming HTTP/HTTPS fetch

The initial client supports scoped streaming GET requests in Eio and Lwt.
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

Each call owns one connection. Completion, early callback return, exception and
cancellation close it; unread bodies are abandoned, never drained for reuse.
Final statuses, including redirects and errors, are returned unchanged. There
is no pooling, automatic redirect, HTTP retry, cookie jar, proxy discovery,
upload API, decompression or protocol handoff. Connection establishment may try
multiple resolved addresses; an HTTP request is never replayed automatically.

## Limits and TLS policy

The default total deadline is30 seconds, covering DNS, connection establishment,
TLS, headers, streaming and the callback. `?timeout` changes it; `?policy` and
`?limits` retain the existing adapter/codec controls. DNS/native blocking work
and user callbacks are subject to the runtime's cancellation capabilities.
Cleanup is joined. TLS teardown attempts a closure alert with a separate maximum
one-second allowance, then closes the underlying transport even if alert output
fails. Arbitrary application finalizers can take longer.

URLs are limited to8192 bytes. Only absolute HTTP/HTTPS URLs are accepted;
userinfo, fragments, raw whitespace/control/non-ASCII bytes, backslashes and
encoded authorities are rejected. Path/query escapes remain encoded. The client
sets Host and Connection: close; callers cannot override framing or connection
control fields. URL validation is not an SSRF policy: applications accepting
untrusted URLs must enforce destination and network-access restrictions.

HTTPS authenticates the URL DNS name or IP address and offers only HTTP/1.1
via ALPN. The upstream TLS2.1.2 Eio/Lwt adapters expose raw EOF and authenticated
TLS closure through the same read outcome. Therefore this client rejects
close-delimited HTTPS responses with `Httpkit_client.Unframed_https_response`
before invoking the response callback. Length-framed, chunked and bodyless
responses remain supported. This deliberately strict compatibility boundary
avoids treating a truncated TLS stream as a complete HTTP response; see
[RFC9112 section9.8](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.8).
Plain HTTP retains the engine's normal close-delimited behavior.

No response body is accumulated by the library. The default codec step bounds
chunks to16KiB; adapters and TLS add their own buffering. Application-retained chunks,
DNS results, trust anchors and concurrent calls are outside that byte bound.
This is not a measured aggregate-memory or sustained-load guarantee.

## Evidence and remaining scope

Local tests cover HTTP and HTTPS, informational responses, chunked trailers,
200KB streaming, non-followed redirects, unread bodies, callback exceptions,
header/callback/TLS-handshake deadlines, joined suspended cleanup, body-scope rejection,
truncated fixed bodies, peer-initiated TLS close, wrong hostname, untrusted certificates and strict
close-delimited HTTPS rejection. Separate installed native/bytecode consumers
check package and runtime isolation. Existing client-engine and both adapter
suites remain part of full validation.

Request-body streaming, pooling, broader DNS/connect/TLS cancellation schedules,
TLS buffer measurements and sustained-resource campaigns remain later work.
The API is experimental; these functional controls do not establish production
readiness.
