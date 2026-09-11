# Routing as a pure primitive

`http-kit-router` depends only on core. Build validated patterns, associate them
with application values, compile a bounded table, then look up a method/target.
The result is a match with captures, no matching path, a method mismatch, or an
input/limit error. The router never invokes handlers or constructs responses.

## Patterns and precedence

| Pattern | Matches | Captures |
| --- | --- | --- |
| `/users/me` | That exact path | None |
| `/users/:id` | One nonempty final segment | `id` |
| `/files/*path` | Zero or more remaining segments | `path`, joined with `/` |

Parameter/wildcard names are unique ASCII identifiers. A wildcard must be last.
A leading `:` or `*` in a pattern segment denotes its reserved pattern syntax.
Literals otherwise retain their exact bytes. Parameters are untyped raw strings;
application-specific identifier parsing is an explicit next step.

Declaration order determines precedence among matching methods. Put `/users/me`
before `/users/:id` when the literal should win. Overlaps are permitted; they are
not silently reordered. If a path matches routes but none matches the requested
method, the result contains distinct allowed methods in declaration order.
There is no implicit GET fallback for HEAD, automatic OPTIONS response, redirect,
or trailing-slash canonicalization. Applications choose those policies.

## Path interpretation

Only origin-form targets starting with `/` are routed. Query strings are excluded
from matching, but still count toward the target byte limit. Absolute-form proxy
requests, CONNECT authorities and `*` require explicit handling outside this
matcher. No URL or query parser is implied by this package.

`%2F` remains `%2F`, so `/users/%2F` captures the string `%2F`, not a slash.
`%2f` and `%2F` retain different spellings. Dot segments, repeated slashes, plus
signs, and trailing slashes also remain unchanged. `/a//b/` differs from `/a/b`.
The wildcard deliberately accepts an empty suffix: `/files/*path` matches both
`/files` and `/files/`, producing an empty capture in those two cases.

Choose decoding and validation once at an application boundary, and use that
same interpretation for authorization and downstream lookup. Captures are not
safe filesystem paths. This library supplies no filesystem or authentication API.

## Bounds and cost

Defaults are 4096 bytes/64 segments per pattern and 1024 routes/8192 target
bytes/64 input path segments per table. Constructors expose overrides and reject
invalid limits before matching. Oversized request targets fail before splitting.
Route-count validation stops at the first excess entry.

The immutable table is an array scanned in order. The input path is split once;
matching cost is bounded by the table and segment limits, plus literal comparisons.
This first implementation is not a trie and makes no constant-time routing claim.
Wildcard capture allocation is deferred until a method matches. Different tables
share no mutable matcher state. Stored values still have their application's own
ownership and concurrency rules.

## Composing middleware and adapters

The router stores any one payload type. A payload can be a handler already wrapped
with `Basic`, `Context`, or `Transition` middleware. Compose endpoint-specific context
transitions before inserting handlers into a table so that the resulting entry
handlers share a common input context. The context guarantees then remain visible
at route registration; heterogeneous context requirements are not erased by a bag
of dynamic values.

[The shared example application](../examples/routing/application.ml) implements
`GET /`, `GET /users/me`, `GET /users/:id`, `GET /files/*path` and `POST /echo`.
It constructs 404/405/400 responses explicitly and uses basic middleware to add a
response header. Two native server programs use this exact application:

```sh
tools/dune-pkg exec ./examples/routing/eio_server.exe
# Or, in another terminal:
tools/dune-pkg exec ./examples/routing/lwt_server.exe
```

Each prints its loopback URL with an automatically selected port. Use that URL
with curl, for example `curl 'http://127.0.0.1:PORT/users/123'`. Ctrl-C stops the
example process. Listeners bind only to loopback, with a backlog of 32, at most 16
active connections, and a 64 KiB collected request-body cap. These are small
application examples, not a deployment template; TLS and application authorization
remain separate concerns.

```sh
python3 tools/test_routing_examples.py
python3 tools/test_router_consumer.py
```

The first check uses Python's independent HTTP client against both servers over
persistent connections: precedence, raw captures, 404/405 and Allow, HEAD body
suppression, middleware headers and binary echo. The second installs only core
and router, checks native/bytecode consumers, and rejects a forged pattern.

`tools/dune-pkg exec ./bench/router_bench.exe` reports time and allocation for
first/last matches, missing paths and method mismatches across 10, 100 and 1000
routes. Every iteration checks its result. These measurements are advisory; a
linear table intentionally trades a small API and explicit precedence for scan
cost. They are not a stable-runner performance approval.
