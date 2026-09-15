# Beta candidate packaging

The source tree prepares package version `0.1.0~beta1` under MIT. This is candidate
metadata, not a published tag or a completed production-confidence gate. The
planned GitHub prerelease name remains `v0.1.0-beta.1`; publication requires owner
review after the [beta plan](beta-plan.md) passes.

All httpkit packages come from the same checkout. The project requires OCaml 5.5.0
and Dune 3.24 or newer; release validation uses the pinned Dune 3.24.1 toolchain.
Keep both Dune lock directories and `toolchain/opam-fixes` when archiving the source.
The database and SQL-session packages require the reviewed local Caqti driver
version, as explained in [dependency fixes](../toolchain/opam-fixes/README.md).
Ordinary central opam resolution alone does not provide that patched version.

The source MIT license does not replace dependency licenses. In particular, the
local Caqti patch retains upstream's LGPL-3.0-or-later WITH LGPL-3.0-linking-exception
license. Preserve upstream notices when distributing dependencies or linked
artifacts. The bundled test fixture in `test/protocol_foundations/closeable_zlib`
retains its ISC notice. A complete runtime/native dependency inventory and fresh archive/opam
installation checks remain release gates; existing Dune installed-consumer checks
are not substitutes for those checks.

No release archive checksum, completed pin-install transcript or published tag is
claimed here until the exact candidate has been built and checked. Public security
reports should use the verified private channel in [SECURITY.md](../SECURITY.md).
