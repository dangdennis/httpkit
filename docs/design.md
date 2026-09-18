# httpkit package design

This document records the current package names and implemented core contracts. The [test plan](test-harness-plan.md) defines the broader security and release requirements.

## Package boundaries

| Package | Responsibility | State |
| --- | --- | --- |
| `httpkit-core` | Immutable checked HTTP metadata and body-polymorphic messages | Implemented in `lib/core` |
| `httpkit-harness` | Development runners, synthetic model, conformance evidence, docs tooling | Implemented for M0–M2 |
| `httpkit-http1` | Independently usable incremental HTTP/1 decoding and encoding | Implemented in `lib/http1` |
| `httpkit-engine` | Sans-I/O client/server lifecycle, body demand, bounded queues, handoff | Implemented in `lib/engine` |
| `httpkit-transport-eio` | Native Eio transport, cancellation, clocks, and body streams | Implemented |
| `httpkit-transport-lwt` | Native Lwt transport, cancellation, clocks, and body streams | Implemented |
| `httpkit-client` | Runtime-neutral URL and request policy | Experimental |
| `httpkit-client-eio` | Scoped streaming HTTP/HTTPS client and bounded pools | Experimental |
| `httpkit-client-lwt` | Scoped streaming HTTP/HTTPS client and bounded pools | Experimental |
| `httpkit-middleware` | Basic, typed-context and transition handler composition | Implemented |
| `httpkit-router` | Bounded raw-path matching with explicit method outcomes | Implemented |
| `httpkit` | Runtime-neutral web primitives: URL/forms, JSON, cookies, HTML, multipart and realtime codecs | Implemented |
| `httpkit-eio` | Eio applications, middleware, files, sessions and realtime connections | Implemented |
| `httpkit-lwt` | Lwt applications, middleware, sessions and realtime connections | Implemented |
| `httpkit-db-eio` | Caqti pools, transactions and migrations for PostgreSQL/SQLite | Implemented |
| `httpkit-cookie` | Encrypted cookie sessions and key rotation | Implemented |
| `httpkit-session-eio` | Shared PostgreSQL/SQLite browser sessions | Implemented |
| `httpkit-password` | Argon2id hashing, verification and rehash policy | Implemented |
| `httpkit-oidc` | Authorization-code/PKCE requests and ID-token policy | Implemented |
| `httpkit-oidc-eio` | Browser login, callback handling and provider requests | Implemented |

Each primitive has one useful public contract and can be consumed independently. Core does not pull in a parser, server, scheduler, or test framework. Codecs depend on core; engines compose codecs; adapters supply I/O and time to engines. An application can use values or codecs without using an engine. Eio and Lwt have their own native APIs, without a shared monadic runtime abstraction.

Production package names are also Dune public library names. Their entry modules capitalize
`Httpkit` and replace hyphens with underscores: `httpkit-core` exposes
`Httpkit_core`, and `httpkit-transport-eio` exposes `Httpkit_transport_eio`.
`httpkit` exposes `Httpkit`; `httpkit-eio` and `httpkit-lwt` expose the application
modules `Httpkit_eio` and `Httpkit_lwt`. Use the `transport` packages for low-level
connections. See the [framework guide](framework.md) and [extensions](extensions.md)
for application APIs and installation examples. Packages are not yet published to opam.

`httpkit-middleware` adds three public composition styles: basic wrappers, typed contexts, and typed context transitions. It depends only on core; see [middleware contracts](middleware.md).

## Core contracts

All input lengths and error offsets count bytes. Defaults are project resource policies, not RFC maxima. Constructors validate before retaining input; errors store only bounded categories and an optional offset. No public unsafe constructor, network operation, global callback registry, or clock exists.

| Primitive | Contract | Default bound | Cost |
| --- | --- | --- | --- |
| `Method` | Nonempty ASCII token; preserve case and extensions | 64 bytes | O(n) time, no input copy |
| `Header.Name` | Nonempty ASCII token; normalize ASCII case | 256 bytes | O(n) time/space |
| `Header.Value` | Empty permitted; opaque high bytes; reject CR/LF/NUL/DEL and other controls except interior HTAB | 8192 bytes | O(n) time, no input copy |
| `Header` | Pair of checked name/value | Per-constructor bounds | O(1) assembly |
| `Headers` | Persistent fields; preserve duplicates and insertion order | 100 fields, 65536 field bytes | O(1) append; O(n) ordered traversal/lookup |
| `Target` | Nonempty URI-character token, valid percent triplets, no fragment or backslash; preserve exact bytes | 8192 bytes | O(n) time, no input copy |
| `Status` | Integer 100–599, including extension codes | Fixed range | O(1) |
| `Request` / `Response` | Immutable metadata with caller-owned polymorphic body | Header collection carries its budget | O(1) creation/body replacement |

Scalar constructors accept explicit byte-limit overrides. Negative limits fail. Collections accept nonnegative count and aggregate byte limits, including zero, and carry them through every append. Aggregate accounting charges name + `": "` + value + CRLF for each field; it excludes the final empty line and is not a serializer. Checks subtract from the remaining budget before addition to prevent integer overflow even with `max_int` limits. Persistence lets callers share older collections; total application retention across separately held versions is the caller's responsibility.

`Header.Value` rejects leading/trailing SP and HTAB as an explicit strict construction policy. A wire parser must remove field-line OWS before constructing it. Interior whitespace and obs-text remain intact. This policy prevents silent normalization at an application boundary while leaving wire syntax handling with the codec. Header names follow [RFC 9110 token grammar](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.2); values follow [field-value restrictions](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.5).

`Headers.get_all` returns every match in insertion order. There is no default comma joining or overwrite behavior: `Set-Cookie` and framing fields make those operations semantically significant. Message-level checks will reject conflicting framing. Core permits two distinct Content-Length fields to be represented for explicit inspection; their presence does not authorize serialization or connection reuse.

`Target` is deliberately lexical. `*`, `/path?query`, absolute URI characters, and authority characters can be represented, but method/target-form compatibility, required authority, IPv6 syntax, Host consistency, and URI semantics are codec responsibilities. Percent triplets, including `%00` and `%0D`, remain encoded; core never decodes or normalizes them. Routers and filesystem integrations need their own interpretation policy. A target is not an already-safe local path.

`Status` follows the [100–599 range](https://www.rfc-editor.org/rfc/rfc9110.html#section-15), without dropping unknown codes. Core has no arbitrary reason-phrase field. HTTP/1.0 and HTTP/1.1 are representable metadata; a version value is not a promise that a later engine supports that version.

Bodies are generic values. `map_body` invokes the caller's function once and can change the type; `with_body` simply replaces it. Core does not close a stream, copy a mutable body, infer a content length, or execute a callback later. An immutable request record does not make its caller-supplied body immutable.

## Security and ergonomics evidence

`test/core` runs an independent byte-table oracle, exact-limit and injection cases, duplicate-order checks, full status-range probes, bounded-error checks, and four seeded properties. These operate on the real public library. They are separate from `test/self`, which tests the synthetic harness. The requirement registry distinguishes the two and keeps unimplemented protocol capabilities pending.

`tools/devlib/consumers.ml` builds and installs only core in a temporary project using the Dune-locked compiler. It compiles and runs bytecode/native consumers with only the installed library include path and stdlib. It also extracts, compiles, and runs the actual odoc example. Invalid constructor coercions and private helper/harness imports must fail compilation for the intended reason. This catches dependency leakage and misleading public examples early.

The isolated staging project disables package mode solely to use Dune 3.24's install command, which is unavailable in package mode. The main workspace remains locked; this test performs no dependency resolution and uses the selected compiler from that lock.

`fuzz/core_fuzz.ml` exercises real constructors through Crowbar; the optional AFL campaign path is currently skipped by request. Historical instrumentation controls are not current campaign evidence. This is an infrastructure/early-regression check; long release campaigns and full protocol fuzz targets remain future work.

`bench/core_bench.ml` reports time and allocated bytes per operation for valid and late-rejected targets at 16/256/8192 bytes and header workloads at 1/10/100 fields. Fixture setup is outside measured work; an opaque identity keeps results observable to the optimizer. Results include compiler and source fingerprints through `tools/devlib/evidence.ml`. There are no pass/fail timing thresholds on developer laptops; stable-runner baselines and repeated statistical comparison are M6 work.

odoc 3.2.1 is pinned in the normal and coverage locks as a development dependency. First-party documentation warnings are fatal. The API reference is authored beside the code in `.mli` files; this document explains cross-module decisions rather than duplicating every signature.

## Current implementation boundary

Core, codecs, engine, adapters and application extensions are implemented. The
active work is the [production-confidence roadmap](protocol-libraries-plan.md),
starting with HTTP/1 adversarial evidence and lifecycle/resource ownership.
See the [architectural audit](production-audit.md) for source paths and concrete
gaps. Historical milestones are not the current feature backlog.

## Consolidation decisions

Receive and send progress are independent private engine states. Completion,
input abort and transfer are explicit; output acknowledgements still control
retirement. No public runtime dependency was added. Adapter admission helpers
accept immutable engine limits and create fresh engines per connection.

Benchmark fixture configuration uses named variants and records. Shared helpers
cover wire construction and input-prefix accounting, while runtime/library
ownership remains visible in each driver. Pipeline correctness includes ordered
request/response identity. See [the consolidation plan](code-quality-plan.md).
