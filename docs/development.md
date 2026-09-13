# Development

Build and validate http-kit from a repository checkout. For usage, start with the
[README](../README.md) and [examples](examples.md).

## Toolchain and dependencies


Prerequisites: mise, a C build toolchain, Python 3, and Git. **mise manages opam; opam manages Dune; Dune package management owns the project compiler and dependencies.** `mise.toml` pins opam 2.5.2. Setup uses that opam to install Dune 3.24.1 in the project-local `dune-bootstrap` switch, then links `.toolchain/bin/dune` to the opam-owned executable. It never copies an unrelated Dune from PATH. Existing global opam switches and shell profiles are untouched.

```sh
mise trust
mise install opam
mise run setup
tools/harness doctor
mise run test
```

Only **OCaml 5.5.0** is supported. Dependencies are declared in `dune-project`; the `.opam` files are generated. `dune.lock/` records the compiler/dependency solution, source checksums, and platform-specific actions for Linux and macOS on x86_64 and arm64. Keep it in version control. `http-kit-harness` owns test and documentation dependencies; production packages have separate dependency closures.

`mise trust` approves this repository's tool/task configuration. The opam switch's OCaml compiler exists only to build Dune; the Dune lock selects OCaml 5.5.0 for http-kit. CI follows the same mise → opam → Dune setup.

The workspace explicitly enables package management. Regular setup and CI consume the existing lock; they never refresh dependency versions. The wrapper rejects a missing lock rather than silently resolving a new one. To deliberately update dependencies, edit `dune-project` (or the repository revision in the workspace files), then run:

```sh
tools/dune-pkg pkg lock
tools/dune-pkg pkg validate-lockdir
tools/dune-pkg build @opam --auto-promote
```

Review the lock diffs and rerun the compiler validation and fuzz smoke. The wrapper selects Dune 3.24.1, a project-local cache, and the workspace/build directory. With that version installed, plain `dune build` also uses the default lock. See [Dune's locking documentation](https://dune.readthedocs.io/en/latest/tutorials/dune-package-management/locking.html).

The workspace pins both opam-repository and Dune's official compatibility overlay. The normal and coverage locks select `ocamlfind.1.9.8+dune`, whose relocatable configuration avoids temporary sandbox paths in Topkg builds. This is a solver constraint; generated lock files are never patched by hand.

## Everyday commands

Run commands from the repository root:

```sh
mise run test
mise run docs
mise run bench
```

Tests use the fast harness tier. Benchmarks retain reports under
`_artifacts/benchmarks/`; timing comparisons are advisory.
After generating API documentation, open
`_build-pkg-5.5.0/default/_doc/_html/http-kit-core/index.html`.

For broader local validation, run the locked compiler, docs, CLI and
installed-consumer checks:

```sh
python3 tools/evidence.py validate 5.5.0
```

## Focused checks

```sh
tools/harness run --suite core --count 1000
tools/harness run --suite http1 --count 1000
tools/harness run --suite engine
tools/dune-pkg runtest test/adapter
python3 tools/test_adapter_consumer.py
```

To inspect the harness and reproduce a deliberately broken subject:

```sh
mkdir -p _artifacts
tools/harness registry
tools/harness example drop-write _artifacts/drop.json
tools/harness replay _artifacts/drop.json
tools/harness replay _artifacts/drop.json --subject drop-write
tools/harness shrink _artifacts/drop.json --subject drop-write --output _artifacts/drop.min.json
```

The correct subject passes; `drop-write` fails with `OUTPUT.EXACT`. Shrinking
preserves the failure category and leaves the original fixture unchanged.

## Further validation

- [Harness contracts](harness-contract.md) and [full test plan](test-harness-plan.md)
- [Interoperability and streaming measurements](interop-performance.md)
- [Benchmarks](benchmarks.md) and [benchmark backlog](benchmark-todos.md)
- [Release assessment](release.md) and [manual completion checklist](m7-manual-checklist.md)

Evidence is source-matched: changes to implementation, tests, toolchain, locks or
API documentation invalidate earlier reports. Local validation and remote CI are
separate results. Release readiness remains incomplete until all required gates
have current evidence.
