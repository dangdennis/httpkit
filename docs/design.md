# httpkit package design

This document records the current package names and implemented core contracts. See [testing](testing.md) for validation and [release policy](release.md) for acceptance.

## Package boundaries

| Package | Responsibility | State |
| --- | --- | --- |
| `httpkit-core` | Immutable checked HTTP metadata and body-polymorphic messages | Implemented in `lib/core` |
| `httpkit-harness` | Development runners, synthetic model, conformance evidence, docs tooling | Development only |
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

`test/core` runs an independent byte-table oracle, exact-limit and injection cases, duplicate-order checks, full status-range probes, bounded-error checks, and four seeded properties. These operate on the real public library. They are separate from `test/self`, which tests the synthetic harness. The requirement registry distinguishes subject controls from harness self-tests.

`tools/devlib/consumers.ml` builds and installs only core in a temporary project using the Dune-locked compiler. It compiles and runs bytecode/native consumers with only the installed library include path and stdlib. It also extracts, compiles, and runs the actual odoc example. Invalid constructor coercions and private helper/harness imports must fail compilation for the intended reason. This catches dependency leakage and misleading public examples early.

Native generated-input checks and benchmarks are described in [testing](testing.md)
and [benchmarks](benchmarks.md). API documentation is authored in public `.mli`
files and built with pinned odoc; first-party documentation warnings are fatal.

## Implementation and readiness

Core, codecs, engine, adapters and application extensions are implemented.
[Status](status.md) records validation and remaining blockers. Package presence
does not imply release approval. Historical consolidation decisions are in the
[implementation record](archive/implementation-history.md).
