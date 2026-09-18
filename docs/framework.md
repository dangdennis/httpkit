# Eio web applications

The framework is three optional packages above the HTTP primitives:

- `httpkit`: bounded parsing, response helpers, cookies/sessions, escaped
  HTML, multipart events, SSE formatting and a WebSocket server codec.
- `httpkit-eio`: application dispatch, lifecycle, common middleware, files,
  in-memory browser sessions and realtime transport loops.
- `httpkit-db-eio`: Caqti pools, transactions and migrations for PostgreSQL and
  file-backed SQLite. Existing typed Caqti requests remain directly usable.

The core, HTTP codecs, router and middleware remain independently composable.
This guide covers the Eio application layer. `httpkit-lwt` provides native Lwt
application dispatch, sessions and realtime helpers; see [extensions](extensions.md).

## Run the example

Starting outside this repository? Follow the [GitHub + database starter](internal-use.md).

```sh
tools/dune-pkg exec examples/framework/server.exe
```

It listens on `0.0.0.0:8080`, or the `PORT` environment variable. SIGTERM/SIGINT
stop admission and drain active HTTP connections. `/health` returns `ok`.
`POST /json` and `POST /form` echo bounded parsed input, `/upload` counts multipart
bytes, `/stream` streams a MiB, `/events` emits SSE, and `/ws` echoes text messages.
The example only enables login if you supply `DEMO_LOGIN_TOKEN`; this is a sample
verification callback, not a password authentication system.

Optional configuration:

| Variable | Purpose |
| --- | --- |
| `APP_ORIGIN` | Exact browser origin for CORS, CSRF and WebSocket checks; default `https://localhost` |
| `STATIC_ROOT` | Directory of public assets; default `public` |
| `DATABASE_URL` | PostgreSQL or file-backed `sqlite3:` URI; enables `/db` |
| `DEMO_LOGIN_TOKEN` | Explicit demonstration bearer credential |

On Railway, configure `APP_ORIGIN` for the public HTTPS origin and use its `PORT`.
Railway owns edge HTTPS; application authentication and authorization remain yours.
Use a persistent volume for SQLite and a single application replica if using the
in-memory session store. PostgreSQL connection settings, including TLS verification,
are delegated to Caqti/libpq and the supplied URI.

## Compose handlers

```ocaml
module App = Httpkit_eio
module Web = Httpkit

let application =
  App.routes ~middleware:[App.Common.security_headers]
    [App.route Httpkit_core.Method.get "/hello/:name" (fun request ->
       let name = Option.value ~default:"world" (App.param "name" request) in
       App.reply (Web.Reply.text ("Hello " ^ name ^ "\n")))]
```

Captures retain raw router bytes. Decode and validate them explicitly with
`Web.Url.decode`; do not decode twice. Query/form pairs preserve duplicates, and
`Web.Url.unique` rejects ambiguous scalar values. Form values allow encoded line
breaks; path decoding rejects controls, separators and dot segments.

`App.read` provides one chunk at a time, and `App.body` collects up to a configured
limit. A request body reader expires after its exchange; concurrent reads fail.
`App.json` checks content type, bounds bytes/nesting, and rejects duplicate keys,
comments, invalid UTF-8 and non-finite numbers. An oversized stream aborts its
connection; a 413 response after partial input is not promised.

`App.reply` accepts a fixed response; `App.stream` accepts a producer whose `send`
function blocks on output capacity. Open producer resources inside the callback:
HEAD requests skip it. The application layer supplies GET fallback for HEAD and
404/405 responses. Errors before headers become a generic 500; errors after
headers abort the response. Exceptions and credentials are not sent to clients.

Defaults are 16 admitted connections, 1 MiB incoming application bodies, 32 KiB
engine output, and a 60-second exchange deadline. Native adapter idle and graceful
shutdown deadlines still apply. `serve` accepts an explicit codec limit profile;
its body quota applies to both directions, independently of the application cap.

## Browser and middleware boundaries

`Common.access_log` records handler completion, request ID, method, path, status
and duration. It omits query strings, cookies, authorization and response bodies;
it does not claim that streaming delivery has completed. Log sinks are callbacks.
`Common.security_headers` sets nosniff, no-referrer and frame denial. Configure an
application-specific CSP separately.

CORS uses exact origins and explicit methods/headers. It is not authentication.
Proxy metadata is ignored unless the immediate peer is explicitly trusted. The
current strict proxy helper accepts a single forwarded IP/protocol; it rejects
chains and `Forwarded` rather than guessing their meaning. Verify your deployment's
header shape before enabling that helper. Forwarded host is never trusted implicitly.

Sessions use opaque random 256-bit identifiers, absolute expiry, rotation and
revocation, with a bounded process-local store. Eio wrappers serialize operations
and require a cryptographic random callback, as demonstrated with `secure_random`.
Cookies default to Secure, HttpOnly, SameSite=Lax and Path=/; the session cookie
uses the `__Host-` prefix. `Sessions.csrf` requires an allowlisted Origin and the
session's `X-CSRF-Token` on unsafe methods. Authentication callbacks supply user
values; password hashing, OAuth and JWT verification are not reimplemented.

## Files and realtime

HTML builders escape text and quoted attributes, reject event/style attributes,
and restrict URL schemes. Raw markup, inline script/style and arbitrary elements
are unavailable. They are safe composition primitives, not a template language.

Multipart parsing is incremental and bounded (100 parts, 8 KiB part headers,
1 MiB per part, 8 MiB total by default). The strict profile rejects preambles,
epilogues, transfer-encoded parts and unsupported quoted-parameter escapes.
Filenames remain metadata. `Files.with_upload` creates exclusive generated files
inside a confined subtree and removes them on completion, error or cancellation;
copy durable data explicitly inside the callback.

Static serving opens a confined Eio subtree, so symlinks cannot escape it. Hidden
paths, traversal and directory listings are rejected. Files are collected up to
8 MiB for content-derived ETags; HEAD and If-None-Match are supported. Ranges,
compression and Last-Modified handling are not part of this initial profile.
Serve only intentional public assets from that root.

SSE formats multiline events and applies normal streaming backpressure. WebSockets
validate masking, lengths, fragmentation, UTF-8 and control frames; the Eio loop
handles ping, partial writes, close acknowledgement and timeouts. Extensions and
subprotocol negotiation are not implemented. Default inbound frame/message caps
are 1 MiB/4 MiB, with a 30-second read/write/callback timeout.

## Database ownership

Create a pool inside an Eio switch, then use `Db.use pool` with a Caqti connection
callback. `Db.transaction pool` commits when the callback returns and rolls back
on exceptions or cancellation. Connections must not escape, run concurrently,
or be used for nested transactions. Failed rollback evicts the connection.
Pools default to eight connections and at most 32 waiting/active-overflow callers;
excess callers raise `Busy`. Closing the wrapper is terminal.

Migrations supply increasing versions and separate PostgreSQL/SQLite SQL lists.
The helper checks stored checksums and history, serializes migration writers
inside the database, and applies the batch transactionally. SQL is trusted source
code; application query parameters belong in typed Caqti requests. PostgreSQL gets
a statement timeout; SQLite gets a bounded lock wait and foreign keys. SQLite
statement execution does not acquire PostgreSQL's timeout guarantee.

## Validation

```sh
tools/dev framework-test
tools/dev consumer framework
tools/dev databases
tools/dev coverage framework
tools/dev mutations framework
tools/dev framework-validate --long
```

Database tests create and stop an isolated PostgreSQL instance. Set
`FRAMEWORK_PG_BIN` if its binaries are not discoverable. Building the Caqti drivers
requires PostgreSQL and SQLite development libraries and pkg-config (plus GMP for
transitive dependencies). See [the roadmap](framework-roadmap.md) for acceptance
status; implementation is separate from public release approval.

The validation coordinator freezes the source hash, retains per-step logs, and
runs the existing regression checks before an isolated profile, a 30-minute
SQLite canary and a two-hour PostgreSQL soak. It never runs AFL. Source edits
invalidate a running measurement; update code and documentation before starting.

Protocol references: [JSON](https://www.rfc-editor.org/rfc/rfc8259),
[cookies](https://www.rfc-editor.org/rfc/rfc6265),
[multipart](https://www.rfc-editor.org/rfc/rfc7578),
[WebSockets](https://www.rfc-editor.org/rfc/rfc6455),
[SSE](https://html.spec.whatwg.org/multipage/server-sent-events.html), and
[Caqti](https://github.com/paurkedal/ocaml-caqti).

## Generated input controls

`fuzz/web_fuzz.ml` adds seeded OCaml targets for URL decoding, forms, raw routing,
multipart and WebSocket frames/reassembly. The shared catalog contains the target
selectors; `dune runtest` runs 200 rounds per target without AFL. A larger local
smoke run is `tools/dune-pkg exec -- fuzz/web_fuzz.exe -r 5000 -s 42`.

Properties cover URL/form round trips and duplicate preservation, raw captures and
router limits, multipart callback order/part budgets/retained parser state, and
WebSocket fragmentation with interleaved ping and close. Complete accepted streams
must agree under whole/byte/random segmentation. Rejections must remain terminal;
partial events preceding a later failure are not required to batch identically.
Generated multipart filenames remain metadata, including traversal-looking names.
These controls do not certify file-system cleanup, network cancellation, total RSS
or WebSocket security; those campaigns remain separate release gates.

`Httpkit.Proxy.resolve` owns the shared pure forwarding policy. Eio/Lwt
`Common.proxy` preserve the existing X-Forwarded-For default and accept an explicit
`~ip_header:Httpkit.Proxy.Real_ip`. Both require authenticated immediate-peer trust,
reject ambiguous selected metadata and never derive origins from forwarded host.
The existing pure `ipaddr` dependency now belongs to this shared implementation;
no new external package version or runtime dependency is introduced.
