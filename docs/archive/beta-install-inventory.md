# Beta archive installation inventory

Snapshot: 2026-09-15, source archive `a21d8ee`, macOS arm64, opam 2.5.2.
See [installation evidence and limitations](../beta-install.md).

This is the **installed build environment**, not the dependency set of every
application or the linked runtime set. It contains 110 opam package records:
16 httpkit runtime packages plus compiler, configuration, build and upstream
packages. The subsequently added test backend (`eio_main` 1.5, `eio_posix` 1.5,
`iomux` 0.4) is excluded from this snapshot. The developer harness was not installed.

Licenses below are opam metadata, not independently verified source notices or
licenses of similarly named OS libraries. Empty declarations are shown explicitly;
the base/virtual packages do not supply a complete compiler/system-library notice.
No vulnerability or redistribution approval is implied. Actual native linkage
and distribution notices require separate review for the release image.

| Package | Installed version | Declared license |
| --- | --- | --- |
| `angstrom` | `0.16.1` | BSD-3-clause |
| `argon2` | `1.0.2` | MIT |
| `asn1-combinators` | `0.3.2` | ISC |
| `astring` | `0.8.5` | ISC |
| `base-bigarray` | `base` | Not declared |
| `base-bytes` | `base` | Not declared |
| `base-domains` | `base` | Not declared |
| `base-effects` | `base` | Not declared |
| `base-nnp` | `base` | Not declared |
| `base-threads` | `base` | Not declared |
| `base-unix` | `base` | Not declared |
| `base64` | `3.5.2` | ISC |
| `bigstringaf` | `0.10.0` | BSD-3-clause |
| `caqti` | `3.0.0` | LGPL-3.0-or-later WITH LGPL-3.0-linking-exception |
| `caqti-driver-postgresql` | `3.0.1+httpkit1` | LGPL-3.0-or-later WITH LGPL-3.0-linking-exception |
| `caqti-driver-sqlite3` | `3.0.0` | LGPL-3.0-or-later WITH LGPL-3.0-linking-exception |
| `caqti-eio` | `3.0.0` | LGPL-3.0-or-later WITH LGPL-3.0-linking-exception |
| `conf-gmp` | `5` | GPL-1.0-or-later |
| `conf-gmp-powm-sec` | `4` | GPL-1.0-or-later |
| `conf-libffi` | `2.0.0` | MIT |
| `conf-pkg-config` | `5` | GPL-2.0-or-later |
| `conf-postgresql` | `2` | blessing |
| `conf-sqlite3` | `1` | blessing |
| `cppo` | `1.8.0` | BSD-3-Clause |
| `csexp` | `1.5.2` | MIT |
| `cstruct` | `6.3.0` | ISC |
| `ctypes` | `0.24.0` | MIT |
| `ctypes-foreign` | `0.24.0` | MIT |
| `digestif` | `1.3.1` | MIT |
| `domain-local-await` | `1.0.1` | ISC |
| `domain-name` | `0.5.0` | ISC |
| `dune` | `3.24.1` | MIT |
| `dune-compiledb` | `0.6.0` | LGPL-2.1-or-later |
| `dune-configurator` | `3.24.2` | MIT |
| `dune-private-libs` | `3.24.2` | MIT |
| `dune-site` | `3.24.2` | MIT |
| `duration` | `0.3.1` | ISC |
| `dyn` | `3.24.2` | MIT |
| `eio` | `1.5` | ISC |
| `eqaf` | `0.10` | MIT |
| `ezjsonm` | `1.3.0` | ISC |
| `fmt` | `0.11.0` | ISC |
| `fpath` | `0.7.3` | ISC |
| `fs-io` | `3.24.2` | MIT |
| `gmap` | `0.3.0` | ISC |
| `hex` | `1.5.0` | ISC |
| `hmap` | `0.8.1` | ISC |
| `httpkit` | `0.1.0~beta1` | MIT |
| `httpkit-cookie` | `0.1.0~beta1` | MIT |
| `httpkit-core` | `0.1.0~beta1` | MIT |
| `httpkit-db-eio` | `0.1.0~beta1` | MIT |
| `httpkit-eio` | `0.1.0~beta1` | MIT |
| `httpkit-engine` | `0.1.0~beta1` | MIT |
| `httpkit-http1` | `0.1.0~beta1` | MIT |
| `httpkit-lwt` | `0.1.0~beta1` | MIT |
| `httpkit-middleware` | `0.1.0~beta1` | MIT |
| `httpkit-oidc` | `0.1.0~beta1` | MIT |
| `httpkit-oidc-eio` | `0.1.0~beta1` | MIT |
| `httpkit-password` | `0.1.0~beta1` | MIT |
| `httpkit-router` | `0.1.0~beta1` | MIT |
| `httpkit-session-eio` | `0.1.0~beta1` | MIT |
| `httpkit-transport-eio` | `0.1.0~beta1` | MIT |
| `httpkit-transport-lwt` | `0.1.0~beta1` | MIT |
| `integers` | `0.8.0` | MIT |
| `ipaddr` | `5.6.2` | ISC |
| `jose` | `0.11.0` | MIT |
| `jsonm` | `1.0.2` | ISC |
| `kdf` | `1.1.1` | BSD-2-Clause |
| `logs` | `0.10.0` | ISC |
| `lru` | `0.3.1` | ISC |
| `lwt` | `6.1.2` | MIT |
| `lwt-dllist` | `1.1.0` | MIT |
| `macaddr` | `5.6.2` | ISC |
| `mirage-crypto` | `2.4.1` | ISC |
| `mirage-crypto-ec` | `2.4.1` | MIT |
| `mirage-crypto-pk` | `2.4.1` | ISC |
| `mirage-crypto-rng` | `2.4.1` | BSD-2-Clause |
| `mtime` | `2.2.0` | ISC |
| `num` | `1.6` | LGPL-2.1-only WITH OCaml-LGPL-linking-exception |
| `ocaml` | `5.5.0` | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception |
| `ocaml-syntax-shims` | `1.0.0` | MIT |
| `ocaml-system` | `5.5.0` | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception |
| `ocamlbuild` | `0.16.1` | LGPL-2.0-or-later WITH OCaml-LGPL-linking-exception |
| `ocamlfind` | `1.9.9~preview` | MIT |
| `ocplib-endian` | `1.2` | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception |
| `ohex` | `0.2.0` | BSD-2-Clause |
| `oidc` | `0.2.0` | BSD-3-Clause |
| `optint` | `0.3.0` | ISC |
| `ordering` | `3.24.2` | MIT |
| `parsexp` | `v0.17.0` | MIT |
| `postgresql` | `5.4.0` | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception |
| `pp` | `2.0.0` | MIT |
| `psq` | `0.2.1` | ISC |
| `ptime` | `1.2.0` | ISC |
| `result` | `1.5` | BSD-3-Clause |
| `seq` | `base` | Not declared |
| `sexplib` | `v0.17.0` | MIT |
| `sexplib0` | `v0.17.0` | MIT |
| `sqlite3` | `5.4.2` | MIT |
| `stdlib-shims` | `0.3.0` | LGPL-2.1-only WITH OCaml-LGPL-linking-exception |
| `stdune` | `3.24.2` | MIT |
| `stringext` | `1.6.0` | MIT |
| `thread-table` | `1.0.0` | ISC |
| `top-closure` | `3.24.2` | MIT |
| `topkg` | `1.1.1` | ISC |
| `uri` | `4.4.0` | ISC |
| `uutf` | `1.0.4` | ISC |
| `x509` | `1.1.1` | BSD-2-Clause |
| `yojson` | `3.0.0` | BSD-3-Clause |
| `zarith` | `1.14` | LGPL-2.0-only WITH OCaml-LGPL-linking-exception |
