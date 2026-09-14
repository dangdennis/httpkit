# Caddy-first application and client library roadmap

Updated 2026-09-14. This replaces the previous protocol expansion plan.
The backend remains HTTP/1.1. Proposed packages below are not yet published.
Existing application APIs remain supported; this roadmap fills their gaps.

## Deployment and ownership

Browser -> Caddy -> local socket or loopback HTTP/1.1 -> httpkit application.
Caddy owns public ingress, certificate automation, response compression, public
static assets and edge routing/load balancing. We build application semantics,
trusted proxy integration, outbound clients and bounded resource ownership.
Remote unencrypted backend links are not the default deployment profile.

Caddy's [reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
supports local upstreams and WebSocket tunnelling. Its
[encode handler](https://caddyserver.com/docs/caddyfile/directives/encode) and
[file server](https://caddyserver.com/docs/caddyfile/directives/file_server)
cover response compression and public assets. These are deployment capabilities,
not evidence that our application has passed an integration test.

No public server TLS package, automatic certificate manager, public asset server,
or response-compression middleware is scheduled. Existing static helpers remain
available for compatibility. Outbound HTTPS, response decoding, private downloads
and WebSocket message handling still belong to the application side.

Keep pure modules independent of runtimes. Eio and Lwt own their native I/O,
clocks, cancellation and cleanup. Reuse maintained crypto, TLS, certificate,
URI, database and compression libraries. Never implement crypto ourselves.
Use OCaml tooling; skip AFL; keep README concise and review each delivered slice.

## Existing baseline and gaps

Already implemented: strict HTTP/1 transport, Eio/Lwt application APIs, routing,
middleware, bounded forms/JSON/multipart, cookies, sessions/CSRF, password and
OIDC wrappers, Eio database integration, SSE and server WebSocket helpers.
Their final release evidence remains separate from implementation status; see
[framework roadmap](framework-roadmap.md). Do not rebuild these as new packages.

Remaining work: prove Caddy deployment behavior; extend typed representation
semantics; provide a usable outbound HTTPS client for OIDC and application calls;
complete bounded codec ownership; stream authorized downloads; finish WebSocket
client/subprotocol/compression behavior and native runtime parity. Existing
[dependency experiments](protocol-foundations.md) support only some of these gates.

## Package and ownership map

| Deliverable | Proposed package / existing home | Implementation boundary |
| --- | --- | --- |
| Trusted proxy identity and deployment lifecycle | Existing middleware, Eio/Lwt adapters and integration harness | Extend existing policy; no Caddy-specific core dependency |
| Typed application headers | `httpkit-headers` / `Httpkit_headers` | Own pure bounded parsing and conditional-request decisions |
| Outbound TLS | Private client backend first | Wrap upstream TLS; publish separate TLS packages only if an independent consumer needs them |
| Client policy | `httpkit-client` / `Httpkit_client` | Own origin, redirect, retry and admission decisions |
| Client runtime | `httpkit-client-eio`, `httpkit-client-lwt` | HTTP/1 connections, resolver, verified TLS, pools and scoped bodies |
| Body codecs | `httpkit-compress` / `Httpkit_compress` | Wrap upstream codecs for outbound decoding, explicit inbound decoding and message compression |
| Authorized file streaming | `httpkit-files-eio`, `httpkit-files-lwt` | Confined descriptors and bounded reads after application authorization |
| WebSocket codec and handshake | `httpkit-ws` / `Httpkit_ws` | Extract existing codec compatibly; add client role and subprotocols |
| Optional WebSocket compression | `httpkit-ws-deflate` | Reuse DEFLATE; own negotiation, message limits and lifetime |
| Sessions/authentication/database parity | Existing extension packages | Close demonstrated gaps and validate integration; reuse upstream crypto and SQL drivers |

Publish each package only when its contract and an independently installed
consumer are useful. Examples after publication:

```sh
opam install httpkit-client-eio httpkit-headers
```

```lisp
(libraries httpkit-client-eio httpkit-headers)
```

```ocaml
module Client = Httpkit_client_eio
module Headers = Httpkit_headers
```

## Phase 1: Caddy integration and application boundary

Extend existing proxy policy before adding a new public helper. Bind backend
listeners locally and explicitly trust the actual proxy peer. Define one canonical
forwarded-header profile: bound chain length/bytes, handle duplicate/conflicting
fields, validate the original host against application policy and derive external
scheme/client address only from trusted input. Never trust a private-range source
merely because it is private. Specify Unix-socket trust separately from IP trust.

Build a pinned, disposable Caddy fixture with a local test CA and versions in the
report. No real domain or public deployment is needed. Exercise both application
runtimes through the proxy: spoofed forwarding headers, HTTPS-aware redirects and
secure cookies, CORS/CSRF origin checks, raw target/Host preservation, body limits,
streaming uploads/downloads, SSE flushing and disconnects, WebSocket upgrade/close,
keep-alive timeout alignment, graceful reload/drain and backend unavailability.
Ensure proxy retries cannot silently duplicate non-replayable application writes.

Document edge/application timeout and body-budget interaction. Client disconnect
must cancel owned work. Health/readiness endpoints must not leak credentials or
report readiness before dependencies are usable. Test shutdown with active requests,
database work and realtime connections. Preserve independent direct HTTP/1 tests.

Exit: real Caddy integration on both runtimes, explicit trust failure controls,
bounded buffers/queues and task cleanup. This is the next implementation slice.

## Phase 2: typed application representation semantics

Build `httpkit-headers`: entity tags, HTTP dates, conditional requests, media-type
negotiation, cache directives and single byte ranges for private representations.
Application state determines validators; Caddy cannot infer database preconditions.
Separate parsers from proceed/not-modified/precondition-failed/range decisions.

Implement weak/strong comparison and precondition ordering, If-Range and HEAD
semantics. Limit field bytes, list items and arithmetic before allocation. Test
wildcards, duplicate fields, q=0, conflicting preconditions, suffix/unsatisfiable
ranges, overflow and date boundaries. Multiple ranges are outside the first profile.
Encoding helpers serve client/codec needs, not a new response-compression layer.

Exit: normative vectors, generated round trips and decisions, bounded allocations,
and an installed consumer without either runtime. Use RFC 9110 as the reference.

## Phase 3: outbound HTTPS and HTTP/1 clients

Build the pure client policy and Eio/Lwt adapters over existing HTTP/1 transports.
Keep TLS integration private initially. Reuse upstream identity verification,
randomness and records; use maintained URI/resolver facilities rather than writing
DNS wire handling. Separate requested host, vetted address, SNI and trust policy.
Advertise only the backend protocol we implement; reject incompatible negotiation.
No verification-disable environment switch, HTTPS downgrade or early data.

Bound resolution/connect/handshake time, handshake input, active connections,
per-origin pools, waiters, idle leases and total request deadline. Response bodies
are scoped: completion, bounded drain or close determines reuse. Never return an
aborted body connection to a pool. Collection helpers require finite byte caps.

Default retries/redirects off, no ambient proxy configuration or cookie jar.
Enabled retries need replayable bodies, attempt/backoff caps and the same deadline.
Redirects need hop limits and credential stripping across origins. Egress policy is
checked for every resolved address and redirect, without globally banning legitimate
private service addresses. Connect only to the address that passed the policy.

Supply this client to existing OIDC adapters: bounded discovery/JWKS/token/userinfo
reads, provider-independent configuration, refresh concurrency and key-rotation
controls. Use a generic local standards-compliant provider for tests. Review auth
failure recovery, session expiry/revocation/rotation, cookie flags and CSRF through
Caddy; do not add new authentication algorithms.

Exit: independent HTTPS peer, expired/untrusted/wrong-host tests, fragmented input,
EOF/cancellation at each stage, pool exhaustion, redirect credential controls,
retry duplication controls and real OIDC flows. Prove Eio/Lwt dependency isolation.

## Phase 4: bounded body decoding and private downloads

Codec work serves application/client needs: optional compressed request bodies,
upstream response decoding and WebSocket compression. Caddy response encoding
does not replace these. Reuse a codec with explicit finish/abort/close semantics;
current native-close experiments are not a supported production backend decision.

Bound encoded input, decoded output, pending chunks, windows and work per step.
Enforce limits before retaining output; ratio alone is insufficient. Specify
checksum, truncation, concatenated members, coding chains and representation-header
changes. Input decoding is opt-in. Do not compress secret-bearing messages mixed
with attacker-controlled data by default. Do not automatically compress SSE.

Private downloads require authorization before opening/streaming. Use descriptor-
relative confinement or an equivalent proven capability boundary. Do not trust
upload filenames as paths. Implement bounded reads, cancellation cleanup, HEAD,
validators and single ranges; test symlink/replacement/rename races. Strong ETags
require immutable/versioned data or a bounded snapshot; mutable files use documented
weaker semantics. Do not hash an unbounded file and reopen it for transmission.
Retain bounded upload cleanup and implement missing Lwt filesystem parity here.

Exit: independent gzip fixtures, malicious expansion/fragmentation, deterministic
native close and native-memory accounting, event-loop fairness, confined-file race
tests and streaming memory independent of total body length. Public file hosting
and dynamic response encoding remain Caddy configuration, not new library work.

## Phase 5: WebSocket and realtime completeness

Extract existing framing/handshake code into `httpkit-ws` without breaking old
module aliases. Add client masking using upstream secure randomness, handshake
verification and offered-subprotocol selection. Preserve explicit browser Origin
policy. Caddy tunnels the connection; the endpoint still owns message semantics.

Add opt-in `httpkit-ws-deflate` only after codec ownership passes. Implement RFC
7692 negotiation with an initial no-context-takeover profile, bounded decoded
messages and interleaved control-frame handling. Never assemble unlimited messages.
Keep SSE queue/backpressure/disconnect behavior explicit in both runtimes.

Exit: role/masking violations, split UTF-8, fragmented messages, control frames,
subprotocol mismatches, close races and independent peers through Caddy and direct
HTTP/1. Replay corpora with OCaml tooling. Test slow consumers and cancellation.

## Delivery estimates and acceptance

| Order | Deliverable | Initial engineer-weeks |
| --- | --- | --- |
| 1 | Caddy integration and application boundary | 1–2 |
| 2 | Application headers | 1–2 |
| 3 | Outbound HTTPS clients and OIDC integration | 4–7 |
| 4 | Body codecs and private downloads on both runtimes | 3–5 |
| 5 | WebSocket/realtime completeness | 2–4 |

Roughly 11–20 engineer-weeks for one engineer, excluding independent audit, blocked
upstream fixes and final release findings. Re-estimate after each dependency gate;
these are planning ranges, not measured delivery predictions. Phases 2 and 3 can
progress independently after deployment contracts settle. No automated scheduling
or deployment is implied by this plan.

Each slice: contract/limits/ownership first, one useful path plus hostile controls,
code-quality review, targeted tests, installed consumer, measured optimization.
Review parsing/arithmetic separately from runtime cancellation and FFI ownership.
Retain deterministic replay/shrinking and fault controls; AFL remains skipped.

Release gates: build/docs; native and ordinary bytecode consumers; runtime isolation;
macOS/Linux; real peers/Caddy; generated and negative tests; coverage gap review;
mutation controls; CPU/allocation/RSS/descriptor/task accounting; a 30-minute canary
and two-hour soak for new runtime paths. Source/workload hashes and platform/native
versions belong in reports. Noisy timing is diagnostic, not a security claim.
Hosted CI and independent security review are separate, explicitly recorded gates.

Never mark a prototype or old evidence as acceptance for changed code. Stop when
pre-allocation bounds, native cleanup, compatibility or event-loop fairness cannot
be demonstrated. Narrow scope or change the dependency; never write custom crypto
to bypass a dependency failure.
