# httpkit

Small, composable HTTP libraries for OCaml. Use checked HTTP values, incremental
HTTP/1 codecs and a Sans-I/O engine independently, or add native Eio and Lwt adapters
for streaming clients and servers.

Core has no dependencies beyond the OCaml standard library. Each adapter uses its
runtime's native concurrency and cancellation model.

For outbound requests, try the experimental [streaming HTTP/HTTPS client](docs/client.md).

Start a separate application with the [GitHub + SQLite/PostgreSQL guide](docs/internal-use.md).
See [validation status](docs/status.md) for passed checks and open issues.

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

## Packages and documentation

Use `httpkit-eio` or `httpkit-lwt` for applications and `httpkit-client-eio` or
`httpkit-client-lwt` for outbound requests. Add database, cookie, session, password
and OIDC packages as needed. The core values, codecs, engine, router and middleware
are independently usable; applications supply listeners and server-side TLS.

- [Documentation index](docs/index.md): guides organized by task.
- [Package reference](docs/design.md): every package, dependency boundary and entry module.
- [Runnable examples](docs/examples.md): from in-memory exchanges to applications.
- [Development](docs/development.md): build, test and generate API documentation.

## Status

Experimental; APIs may change. Local suites have passed, but broad internal
rollout and public release are not yet signed off. [Remaining work](docs/status.md).
See the [security policy](SECURITY.md) for reporting guidance.
