# httpkit

Small, composable HTTP libraries for OCaml. Use checked HTTP values, incremental
HTTP/1 codecs and a Sans-I/O engine independently, or add native Eio and Lwt adapters
for streaming clients and servers.

Core has no dependencies beyond the OCaml standard library. Each adapter uses its
runtime's native concurrency and cancellation model.

For outbound requests, try the experimental [streaming HTTP/HTTPS client](docs/client.md).

Start a separate application with the [GitHub + SQLite/PostgreSQL guide](docs/internal-use.md).
See [validation status](docs/status.md) for passed checks and the unresolved profiling hang.

## Get started

Requires **OCaml 5.5.0**. To work from this repository, install mise, a C build
toolchain and Git, then run these commands from the checkout:

```sh
mise trust
mise install opam
mise run setup
```

Setup provisions the compiler and locked dependencies locally through
mise → opam → Dune. See [development](docs/development.md) for toolchain details
and dependency updates.

## Try it with Eio

Run a complete HTTP client/server exchange over a local socket pair:

```sh
tools/dune-pkg exec ./examples/runtime/eio_example.exe
```

It prints `Hello /`. The [Eio example](examples/runtime/eio_example.ml) owns the
connection lifetimes with switches, sends a request, and collects the response.
Both sides run in one process; no listening port is needed.

The server uses this [pure handler](examples/runtime/transform.ml):

```ocaml
open Httpkit_core

let handle request =
  let body = "Hello " ^ Target.to_string (Request.target request) ^ "\n" in
  let headers =
    Result.get_ok
      (Headers.of_list
         [ ("content-length", string_of_int (String.length body)) ])
  in
  Response.create ~status:Status.ok ~headers body
```

The executable links `httpkit-transport-eio` and `eio_main`; the handler needs only
`httpkit-core`. This small example collects bodies; use the adapter's streaming
operations for larger transfers and configure limits for your application.

Prefer Lwt? Run the [equivalent example](examples/runtime/lwt_example.ml):

```sh
tools/dune-pkg exec ./examples/runtime/lwt_example.exe
```

## Packages

| Package | Use it for |
| --- | --- |
| `httpkit-core` | Checked headers, methods, targets and body-polymorphic messages |
| `httpkit-http1` | Incremental HTTP/1 decoding, encoding and framing validation |
| `httpkit-engine` | Sans-I/O client/server connections with bounded queues and backpressure |
| `httpkit-transport-eio` | Native Eio transport, streaming, deadlines and cancellation |
| `httpkit-transport-lwt` | Native Lwt transport, streaming, deadlines and cancellation |
| `httpkit-client` | URL and outbound request policy |
| `httpkit-client-eio` | Eio streaming HTTP/HTTPS requests and origin pools |
| `httpkit-client-lwt` | Lwt streaming HTTP/HTTPS requests and origin pools |
| `httpkit-middleware` | Basic wrappers, typed contexts and typed context transitions |
| `httpkit-router` | Declaration-ordered path matching and explicit method outcomes |
| `httpkit` | URL/forms, JSON, cookies, sessions, HTML, multipart, SSE and WebSocket primitives |
| `httpkit-eio` | Eio application dispatch, middleware, files and realtime connections |
| `httpkit-lwt` | Lwt application dispatch, middleware, sessions and realtime connections |
| `httpkit-db-eio` | PostgreSQL/SQLite pools, transactions and migrations through Caqti |
| `httpkit-cookie` | Encrypted cookie sessions and key rotation |
| `httpkit-session-eio` | Shared PostgreSQL/SQLite browser sessions |
| `httpkit-password` | Argon2id hashing, verification and rehash policy |
| `httpkit-oidc` | Authorization-code/PKCE requests and ID-token policy |
| `httpkit-oidc-eio` | Browser login and provider integration for Eio applications |

Applications supply listeners and TLS. Codecs and engines can also be used with
other runtimes through their explicit input, output and event interfaces.

## Documentation

- [Documentation index](docs/index.md) and [current validation status](docs/status.md)
- [Start a new application from GitHub](docs/internal-use.md)
- [Install candidate packages with opam](docs/beta-install.md)
- [Eio web application guide](docs/framework.md)
- [Sessions, login and Lwt applications](docs/extensions.md)
- [Runnable examples](docs/examples.md)
- [Core values and package design](docs/design.md)
- [HTTP/1 contracts](docs/http1.md), [engine contracts](docs/engine.md) and [native adapters](docs/adapters.md)
- [Routing](docs/routing.md) and [middleware](docs/middleware.md)
- [Development and API documentation](docs/development.md)

## Status

Experimental; APIs may change. Local suites have passed, but broad internal
rollout and public release are not yet signed off. [Remaining work](docs/status.md).
See the [security policy](SECURITY.md) for reporting guidance.
