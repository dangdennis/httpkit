# Dependency review

Initial advisory inspection: 2026-09-14; local cancellation patch review:
2026-09-15; PostgreSQL driver replaced: 2026-11-21. This is a scoped maintainer
review of locked packages, published upstream advisories and native linkage. It
is not a complete vulnerability scan or an independent security approval. Full
deployment dependency review remains open. The September advisory and linkage
passes predate the driver change and did not cover sqlkit.

## Boundaries and necessity

Core values have no third-party runtime dependency. HTTP/1 adds `ipaddr` for
authority validation; the engine adds only our core and codec. Keep these layers
free of database, authentication, TLS and runtime-backend dependencies.

| Area | Locked dependency / purpose | Review boundary |
| --- | --- | --- |
| Runtime transport/application | Eio 1.5 | Cancellation, provider/backend and native resource semantics |
| HTTP/application values | ipaddr 5.6.2, Yojson 3.0.0, Base64, Digestif 1.3.1, Eqaf 0.10 | Parsing limits, encoded lengths, hashing and equality |
| Database | PostgreSQL: sqlkit, sqlkit-pool-eio and sqlkit-pgwire 0.1.0 (Git pin, pure OCaml). SQLite: Caqti 3.0.0 with SQLite driver 3.0.0 | PostgreSQL wire protocol, authentication and TLS in OCaml (new, not independently reviewed); native SQLite library; transactions, rollback, lease scope |
| Cookie protection | Mirage Crypto 2.4.1 plus its RNG | Upstream authenticated encryption; our key/nonce/configuration and expiry policy |
| Passwords | ocaml-argon2 1.0.2 plus native libargon2 | Synchronous native work, cost limits and caller-owned worker admission |
| OIDC | jose 0.11.0, oidc 0.2.0, upstream cryptographic dependencies | Algorithm/key policy, verification, claims and remote-client trust |
| Outbound fetch | Uri 4.4.0; tls-eio 2.1.2 and existing TLS/X509 stack | Separate client package; hostname/IP authentication, ALPN, framing and cleanup |

The fetch examples use ca-certs 1.0.3 for system trust discovery; it adds bos 0.3.0
and rresult 0.7.0 to the harness closure. The client libraries accept an explicit
authenticator and do not depend on CA-store discovery. The normal and coverage
locks include these dependencies. Since 2026-11-21 `sqlkit-pgwire` also depends
on ca-certs, tls-eio and x509, so they are in the `httpkit-db-eio` closure: the
driver falls back to the system trust store when a verifying `sslmode` is used
without `sslrootcert`. This boundary review
is not a refreshed comprehensive advisory audit.

These are separate trust boundaries, not reasons to write replacement crypto.
The development harness also installs comparison, test and profiling packages;
its entire lock inventory is not the dependency set of every production package.
Review installed package closures separately from the all-packages workspace.

The [macOS archive-install inventory](archive/beta-install-inventory.md) records the
actual opam package versions and declared licenses for the `a21d8ee` installation.
Its 110 entries include build tools and compiler/configuration packages; they are
not all runtime dependencies. This resolution used the pinned central repository
and local PostgreSQL fix, separately from Dune's overlay-based locks. In particular,
it selected ctypes 0.24.0 and ocamlfind 1.9.9~preview. The installed native/bytecode
consumer controls passed, but that does not transfer all locked-workspace evidence
to these versions. Final platform, advisory and distribution review remains open.
That inventory predates the 2026-11-21 driver change: it lists the removed
`caqti-driver-postgresql` and `postgresql` packages and has no sqlkit, decimal or
uuidm entries. No opam resolution has been repeated since.

The application library depends on `eio` interfaces. Backend selection belongs
to the executable; examples select `eio_main` explicitly. An isolated installed
consumer reproduced the old unnecessary `eio_main` requirement, and now builds
and runs application composition in native and bytecode modes without
`eio_main`, `eio_posix` or `eio_linux` installed. This bounded package cleanup
does not justify merging independent database/authentication packages.

## PostgreSQL driver

Since 2026-11-21 PostgreSQL runs on sqlkit's pure OCaml driver, `sqlkit-pgwire`.
It speaks the wire protocol over Eio: no libpq, no `postgresql` OCaml binding and
no C stubs for PostgreSQL. SQLite still runs on Caqti (`caqti-driver-sqlite3`).

sqlkit is not on opam. `dune-project` pins three packages, all version 0.1.0, to
one Git revision:

```
git+https://github.com/dangdennis/sqlkit.git#77241d9f76365f58578e1e7fd0c4a6ca6ef67f17
```

| Package | Role |
| --- | --- |
| `sqlkit` | Connection handle, limits, errors, transactions; adds decimal 1.0.2 and uuidm 0.9.10 to the lock |
| `sqlkit-pool-eio` | Eio connection pool used by the driver |
| `sqlkit-pgwire` | Wire protocol, authentication, TLS and connection-string parsing |

Both lock directories record that revision for each package. The lock's
repository list is `complete true` again; re-resolving needs only the pinned
remote repositories and the Git pin. sqlkit declares the MIT license.

Removed from the project and both locks: `caqti-driver-postgresql`
(`3.0.1+httpkit1`), `postgresql.5.4.0` and `conf-postgresql`. The local opam
repository `toolchain/opam-fixes` is deleted and no longer listed in
`dune-workspace` or `dune-workspace.coverage`.

**Review state.** The driver implements trust, cleartext-password, MD5 and
SCRAM-SHA-256 authentication (no channel binding) and TLS negotiation
(`sslmode`, `sslrootcert`) on top of tls-eio, x509, Digestif and Mirage Crypto's
RNG. That authentication and TLS code is new. It had one adversarial review on
2026-11-21, whose twelve findings are fixed in the pinned commit, but **no
review by an independent party**. It has no published advisory history to consult, and it was not part
of the September advisory pass below. The driver has the same author as httpkit;
it is not an independently maintained upstream. Treat PostgreSQL credentials and
transport security on this path accordingly until that review exists.

### History: Caqti cancellation fix (2026-09-15, no longer applies)

Until 2026-11-21 PostgreSQL used Caqti with a locally patched driver. A real
in-flight cancellation control had reproduced a stuck driver busy flag and
failed disconnect; the local `3.0.1+httpkit1` patch cleared the flag in a
finalizer even when reset cleanup failed or was cancelled. `httpkit-db-eio`
required that exact version from the local `toolchain/opam-fixes` repository,
and Dune marked the repository list `complete false` because of it. The patch,
the local repository and that requirement are gone with the driver. The
observed-query cancellation schedule remains in the regular database suite and
passed on 2026-11-21 against the new driver.

The separate [`postgresql.5.4.0` bytecode crash](status.md#what-we-found) was in
the same removed stack and is closed by removal, not by a fix to that binding.

## Published advisory review

GitHub's public repository-advisory API was queried for Mirage Crypto, Caqti,
Eio, ocaml-argon2, reference libargon2, ocaml-jose and ocaml-oidc. The first
five and ocaml-oidc returned empty published-advisory lists. Empty lists do not
cover unpublished reports, other advisory databases, all transitives, or OS
libraries. Raw responses and repository metadata are retained locally under
`_artifacts/production-slices/22-*-advisories.json` and `22-*-repository.json`.
The Caqti result now matters only for the SQLite path. sqlkit, decimal and uuidm
were not queried.

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

That September listing is history for libpq. On 2026-11-21 `otool -L` on the
rebuilt macOS database test binary (`test/db_eio/db_test.exe`) showed system
SQLite, GMP and libSystem only; libpq is no longer a system dependency of
httpkit. pkg-config, GMP, libffi, libargon2 and SQLite remain, depending on the
selected packages. The authentication test binaries and Linux were not
re-inspected.

Before release, retain the production image/OS package inventory, actual loaded
library identities and applicable advisories; review the complete installed
transitive closure, source/build provenance and licenses; and rerun installation,
cryptographic negative controls and backend cancellation tests after dependency
changes. Broader advisory coverage and a named independent review remain open.
Do not infer production approval from this initial published-advisory pass.
