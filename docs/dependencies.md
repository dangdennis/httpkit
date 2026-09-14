# Dependency review

Inspection date: 2026-09-14. This is a scoped maintainer review of locked packages,
published upstream advisories and native linkage. It is not a complete
vulnerability scan or an independent security approval. P0-09 remains open.

## Boundaries and necessity

Core values have no third-party runtime dependency. HTTP/1 adds `ipaddr` for
authority validation; the engine adds only our core and codec. Keep these layers
free of database, authentication, TLS and runtime-backend dependencies.

| Area | Locked dependency / purpose | Review boundary |
| --- | --- | --- |
| Runtime transport/application | Eio 1.5 or Lwt 6.1.2 | Cancellation, provider/backend and native resource semantics |
| HTTP/application values | ipaddr 5.6.2, Yojson 3.0.0, Base64, Digestif 1.3.1, Eqaf 0.10 | Parsing limits, encoded lengths, hashing and equality |
| Database | Caqti 3.0.0 with PostgreSQL/SQLite drivers | Native client libraries, transactions, rollback, lease scope |
| Cookie protection | Mirage Crypto 2.4.1 plus its RNG | Upstream authenticated encryption; our key/nonce/configuration and expiry policy |
| Passwords | ocaml-argon2 1.0.2 plus native libargon2 | Synchronous native work, cost limits and caller-owned worker admission |
| OIDC | jose 0.11.0, oidc 0.2.0, upstream cryptographic dependencies | Algorithm/key policy, verification, claims and remote-client trust |

These are separate trust boundaries, not reasons to write replacement crypto.
The development harness also installs comparison, test and profiling packages;
its entire lock inventory is not the dependency set of every production package.
Review installed package closures separately from the all-packages workspace.

The application library depends on `eio` interfaces. Backend selection belongs
to the executable; examples select `eio_main` explicitly. An isolated installed
consumer reproduced the old unnecessary `eio_main` requirement, and now builds
and runs application composition in native and bytecode modes without
`eio_main`, `eio_posix`, `eio_linux` or Lwt installed. This bounded package cleanup
does not justify merging independent database/authentication packages.

## Published advisory review

GitHub's public repository-advisory API was queried for Mirage Crypto, Caqti,
Eio, Lwt, ocaml-argon2, reference libargon2, ocaml-jose and ocaml-oidc. The first
six and ocaml-oidc returned empty published-advisory lists. Empty lists do not
cover unpublished reports, other advisory databases, all transitives, or OS
libraries. Raw responses and repository metadata are retained locally under
`_artifacts/production-slices/22-*-advisories.json` and `22-*-repository.json`.

JOSE publishes [CVE-2023-23928 / GHSA-7jj9-6qwv-wpm7](https://github.com/ulrikstrid/ocaml-jose/security/advisories/GHSA-7jj9-6qwv-wpm7):
versions below 0.8.2 failed to verify HS256 signatures. Our lock already uses
0.11.0, and our OIDC profile permits only RS256 and ES256. This finding does not
establish exposure of the current OIDC implementation. It does expose missing
installation constraints: `httpkit-oidc` now requires at least the tested JOSE
0.11.0 release. Existing ordinary and coverage dependency versions are unchanged.

Native/bytecode authentication tests retain a valid signed-token control, mutate
every RSA signature byte, change a valid subject while retaining the old signature,
and reject HS256, `none` and empty signatures. These complement issuer, audience,
nonce, expiry, key-selection and duplicate-claim controls. They test our supported
profile, not every upstream JOSE algorithm.

The inspected upstream repositories were neither archived nor disabled. Last-push
metadata ranges from 2024 for the Argon2 binding/reference implementation to
September 2026 for several other libraries; this is activity evidence, not a
maintenance-quality or security verdict. In particular, stable cryptographic code
does not become unsafe merely because releases are infrequent.

## Native dependencies and outstanding evidence

`otool -L` on the local authentication/database test binaries shows native GMP,
libffi, libargon2, libpq and system SQLite linkage. Build-time `pkg-config`
versions are retained separately in `22-native-pkgconfig.log`; they are not
substitutes for actual runtime-library versions. On this host the metadata and
linked library identities differ, so they must not be combined into a fabricated
single version inventory. Dune locks do not pin the runtime OS shared libraries.

Before release, retain the production image/OS package inventory, actual loaded
library identities and applicable advisories; review the complete installed
transitive closure, source/build provenance and licenses; and rerun installation,
cryptographic negative controls and backend cancellation tests after dependency
changes. Broader advisory coverage and a named independent review remain open.
Do not infer production approval from this initial published-advisory pass.
