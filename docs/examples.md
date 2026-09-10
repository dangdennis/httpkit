# Working with the public primitives

These examples use OCaml 5.5.0 and the locked dependencies. They are executable
starting points; they are not a production deployment or security approval.

## In-memory streaming, without a runtime adapter

```sh
tools/dune-pkg exec ./examples/pure/in_memory.exe
```

Expected output is `Hello /stream` followed by a newline. The example links only
`http-kit-core` and `http-kit-engine` (which depends on the HTTP/1 codec).
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

These existing adapter examples collect small bodies. Fully worked streaming and
cancellation recipes remain the next example tasks; the adapter contracts and
lifecycle tests already cover those operations. See [adapter ownership and
limits](adapters.md) before adapting a recipe to a long-lived application.
