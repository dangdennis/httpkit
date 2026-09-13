# http-kit

Small, composable HTTP libraries for OCaml. Use checked HTTP values, incremental
HTTP/1 codecs and a Sans-I/O engine independently, or add native Eio and Lwt adapters
for streaming clients and servers.

Core has no dependencies beyond the OCaml standard library. Each adapter uses its
runtime's native concurrency and cancellation model.

## Get started

Requires **OCaml 5.5.0**. To work from this repository, install mise, a C build
toolchain, Python 3 and Git, then run these commands from the checkout:

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
open Http_kit_core

let handle request =
  let body = "Hello " ^ Target.to_string (Request.target request) ^ "\n" in
  let headers =
    Result.get_ok
      (Headers.of_list
         [ ("content-length", string_of_int (String.length body)) ])
  in
  Response.create ~status:Status.ok ~headers body
```

The executable links `http-kit-eio` and `eio_main`; the handler needs only
`http-kit-core`. This small example collects bodies; use the adapter's streaming
operations for larger transfers and configure limits for your application.

Prefer Lwt? Run the [equivalent example](examples/runtime/lwt_example.ml):

```sh
tools/dune-pkg exec ./examples/runtime/lwt_example.exe
```

## Packages

| Package | Use it for |
| --- | --- |
| `http-kit-core` | Checked headers, methods, targets and body-polymorphic messages |
| `http-kit-http1` | Incremental HTTP/1 decoding, encoding and framing validation |
| `http-kit-engine` | Sans-I/O client/server connections with bounded queues and backpressure |
| `http-kit-eio` | Native Eio transport, streaming, deadlines and cancellation |
| `http-kit-lwt` | Native Lwt transport, streaming, deadlines and cancellation |
| `http-kit-middleware` | Basic wrappers, typed contexts and typed context transitions |
| `http-kit-router` | Declaration-ordered path matching and explicit method outcomes |

Applications supply listeners and TLS. Codecs and engines can also be used with
other runtimes through their explicit input, output and event interfaces.

## Documentation

- [Runnable examples](docs/examples.md)
- [Core values and package design](docs/design.md)
- [HTTP/1 contracts](docs/http1.md), [engine contracts](docs/engine.md) and [native adapters](docs/adapters.md)
- [Routing](docs/routing.md) and [middleware](docs/middleware.md)
- [Development and API documentation](docs/development.md)

## Status

Experimental; APIs may change and release validation is incomplete.
See the [security policy](SECURITY.md) for reporting guidance.
