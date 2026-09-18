# Working with the public primitives

These examples use OCaml 5.5.0 and the locked dependencies. They are executable
starting points; they are not a production deployment or security approval.

For a complete starter with routes, migrations and SQLite/PostgreSQL, follow
[the new-repository tutorial](internal-use.md). Its source is
[`examples/starter/main.ml`](../examples/starter/main.ml).

## In-memory streaming, without a runtime adapter

```sh
tools/dune-pkg exec ./examples/pure/in_memory.exe
```

Expected output is `Hello /stream` followed by a newline. The example links only
`httpkit-core` and `httpkit-engine` (which depends on the HTTP/1 codec).
No Eio or Lwt types enter this application.

Read [the source](../examples/pure/in_memory.ml) in this order:

1. Construct validated request metadata and submit it to a client engine.
2. Move at most three wire bytes at a time from one engine to the other. Pass the
   actual consumed count to `acknowledge`; do not assume the entire slice was read.
3. Drain application events. Receiving `Request` provides metadata; `Complete`
   marks completion of the incoming body. The server waits for that event before
   sending this example's response.
4. Submit a response head, three body chunks, and an end command. Keep each
   application command pending until it returns `Accepted`. Retry only
   `Backpressured` commands, whose documented contract guarantees no effect.
5. Read owned response `Data` chunks and stop at `Complete`. The example collects
   a tiny body to check the result; a streaming consumer processes chunks without
   retaining the entire body.

The client and server use different output budgets (128 and 64 bytes), while the
transport transfers three bytes per step. The example's loop is intentionally a
small bounded demonstration. A real adapter waits for readiness and cancellation
instead of spinning. Both native and bytecode versions run under `dune runtest`. The installed-consumer
check also compiles this exact source outside the repository with only the
installed protocol packages available.

## The same pure handler with native adapters

```sh
tools/dune-pkg exec ./examples/runtime/eio_example.exe
tools/dune-pkg exec ./examples/runtime/lwt_example.exe
```

Both print `Hello /` and call the same pure
[handler](../examples/runtime/transform.ml). Each uses a local socket pair to make
client/server cleanup reproducible. Eio owns fibers and switches; Lwt owns promises
and cancellation. There is no shared promise interface in the production core.

These small adapter examples collect bodies. The [Eio personal-use examples](personal-eio.md)
add incremental upload/download, routing and middleware, peer cancellation, and
graceful shutdown with active transfers. See [adapter ownership and limits](adapters.md)
before adapting a recipe to a long-lived application.

Routing examples decide whether to consume the upload before reading its body.
A supported Expect upload receives 100 Continue first; unmatched routes receive
a final response immediately. Early final responses follow the engine close
policy and do not wait for the client to transmit a rejected upload.

The `/protected` route demonstrates Transition context plumbing in both native
runtimes. The Eio wrapper yields and the Lwt wrapper binds a promise before
supplying an `Application.authenticated` context to the endpoint. Requests with
`x-demo-user: demo` get the illustrative identity; missing/other values receive
401. This is an executable composition example, not an authentication protocol.
Public routes continue through the same shared Basic middleware application.
