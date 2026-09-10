# http-kit

An OCaml HTTP toolkit being built from independently usable primitives, with native Eio and Lwt adapters above a sans-I/O engine.

**Current scope: M0–M1 harness, M2 core values, M3 HTTP/1 codecs, M4 engines, and M5 native adapters.** `http-kit-core` has no runtime dependencies beyond OCaml's standard library. `http-kit-http1` adds incremental head/body decoding, strict framing validation, and encoding. `http-kit-engine` adds bounded sans-I/O client/server connections. `http-kit-eio` and `http-kit-lwt` provide scoped native drivers, deadlines, bounded admission and body collection. Release evidence remains a separate gate.

The [package design](docs/design.md) records current APIs and ownership decisions. The [full test plan](docs/test-harness-plan.md) describes security and release gates; the [harness contract](docs/harness-contract.md) distinguishes synthetic models from real core tests.

## Use the core

Link `(libraries http-kit-core)` and construct checked values:

```ocaml
open Http_kit_core
let ( let* ) = Result.bind

let request path =
  let* target = Target.of_string path in
  let* headers = Headers.of_list ["accept", "application/json"] in
  Ok (Request.create ~meth:Method.get ~target ~headers ())
```

`Method`, `Header.Name`, `Header.Value`, `Target`, and `Status` have opaque types and checked constructors. `Headers` preserves duplicate fields and order, with count and byte budgets. Requests and responses are polymorphic in their body; `map_body` can change its type without changing metadata. Errors contain a category and optional byte offset, never untrusted input.

Targets retain raw bytes and escapes. This is lexical validation: the HTTP/1 codec additionally checks target forms, Host, framing conflicts, and status/method-specific body rules. See [the precise limits and contracts](docs/design.md#core-contracts).

## Setup

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

## API docs and core checks

Both locks pin **odoc 3.2.1**, the [latest published release checked on 2026-09-10](https://github.com/ocaml/odoc/releases/tag/3.2.1). First-party odoc warnings are fatal. Public interface comments document byte limits, complexity, ownership, and validation boundaries.

```sh
mise run docs
tools/harness run --suite core --count 1000
python3 tools/test_core_consumer.py
mise run bench
```

Open `_build-pkg-5.5.0/default/_doc/_html/http-kit-core/index.html` after generating docs. The installed-consumer check builds only core in an isolated project using the locked compiler, installs it to a temporary prefix, then compiles/runs bytecode and native consumers and the actual odoc example. Negative fixtures verify opaque constructors and private-module isolation. The staging project disables package management because Dune 3.24 does not support `dune install` in package mode; ordinary project builds and dependency resolution continue to use the locks.

Benchmarks report raw nanoseconds and allocated bytes per operation for target validation, header construction, append, and lookup over geometric input sizes. They are initial local measurements without a regression threshold; they do not measure network throughput.

## HTTP/1 codec checks

```sh
tools/harness run --suite http1 --count 1000
python3 tools/test_protocol_consumer.py
tools/dune-pkg exec ./bench/http1_bench.exe
tools/harness readiness --milestone M3
```

The codec reports exactly how many input bytes it consumed, leaves pipeline/tunnel suffixes with the caller, and performs bounded work per call. It supports fixed-length, chunked (including extensions and declared trailers), and close-delimited response bodies. Head encoding validates authority and framing before returning bytes; body encoding enforces exact lengths. See [codec policy and ownership](docs/http1.md) and the generated `http-kit-http1` odoc pages.

The codec suite tests all single split points for its golden heads and selected bodies, truncated input, ambiguous framing, strict syntax, limits, and outbound misuse. AFL smoke now includes request, response, and chunked fragmentation oracles, with valid seeds and uninstrumented replay of discovered queue entries. These are small smoke budgets, not release campaigns.

## Replay a deliberately broken subject

```sh
mkdir -p _artifacts
tools/harness example drop-write _artifacts/drop.json
tools/harness replay _artifacts/drop.json
tools/harness replay _artifacts/drop.json --subject drop-write
tools/harness shrink _artifacts/drop.json --subject drop-write --output _artifacts/drop.min.json
```

The correct subject passes the fixture. The `drop-write` subject fails with `OUTPUT.EXACT` and exit code 1. Replay creates a new subject and executes every action. Shrinking retains the failure category and required setup actions. It never changes the original fixture.

```sh
tools/harness run --suite property --seed 42 --count 1000
tools/harness run --report _artifacts/results.json --junit _artifacts/results.xml
tools/harness registry
tools/harness readiness --milestone M1
tools/harness readiness --release
```

Release readiness deliberately returns `NOT_IMPLEMENTED` and exit code 3. Unknown suites/tier names cannot silently select an empty passing test run. Exit codes: 0 success, 1 test failure, 2 infrastructure/invalid invocation, 3 required work unimplemented.

## Compiler and instrumentation evidence

```sh
python3 tools/evidence.py validate 5.5.0
mise run setup:afl
python3 tools/fuzz-smoke.py
tools/harness readiness --milestone M0
tools/harness readiness --milestone M2
```

Compiler validation builds docs and runs deterministic/property tests, actual CLI tests, installed consumers, and core benchmarks. Core tests exhaustively classify all 256 byte values, probe exact resource limits, and exercise injection, percent escapes, duplicate order, and body ownership.

**mise manages AFL++ setup through `tools/setup-afl.sh`.** `toolchain/afl.version` pins the official source URL, tag, and full commit; setup verifies the revision and tracked-source cleanliness before building `afl-fuzz` and `afl-showmap`. Python no longer downloads or builds AFL++. The remaining Python scripts orchestrate toolchain setup, subprocesses, and evidence; the production library, models, properties, and fuzz targets are OCaml.

Fuzz smoke verifies different OCaml coverage maps, discovers planted native/Crowbar faults, replays them uninstrumented, then runs separate synthetic-harness and real-core targets. First-party code is instrumented; no wire-protocol or third-party coverage claim is made. Run fuzz smoke after compiler validations finish because they share the normal build directory.

The fuzzer uses SysV shared memory. A restrictive macOS sandbox may prevent allocation; that is an infrastructure failure, not a passing smoke test. Run it in a suitable local environment or use the Linux CI job. No system `sysctl` settings are modified by the scripts.

M0 readiness requires source-matched evidence from OCaml 5.5.0 and the fuzz smoke. M2 additionally requires installed-consumer/docs/benchmark evidence on OCaml 5.5.0 and the real core fuzz smoke. Editing implementation, tests, toolchain, workspace, API documentation, or lock files invalidates prior evidence. Reports identify the selected lock and its packages. M1 readiness executes its own self-tests. These gates do not assert remote CI completion or internet-facing protocol readiness.

The CI workflow checks Linux and macOS on OCaml 5.5.0, with a separate Linux instrumentation job. It is configured in the repository; it has not run merely because a local validation passed.

## Next boundary

M4’s [engine contract](docs/engine.md) covers: bounded events/output, exactly-once commands, partial acknowledgements, persistence, cancellation, early responses, and handoff. Native Eio and Lwt adapters now implement these contracts; see [adapter ownership and policy](docs/adapters.md). The [design](docs/design.md#next-implementation-boundary) records the sequence.

Run `tools/harness run --suite engine` and `tools/harness readiness --milestone M4` for engine tests and source-matched readiness.

## Native adapters

Run the complete socket-pair examples:

```sh
tools/dune-pkg exec examples/runtime/eio_example.exe
tools/dune-pkg exec examples/runtime/lwt_example.exe
tools/dune-pkg runtest test/adapter
python3 tools/test_adapter_consumer.py
tools/harness readiness --milestone M5
```

Both examples link the exact same [pure handler](examples/runtime/transform.ml).
Use `with_connection` for transport ownership, `next_event` for streaming,
`send`/`finish` for bounded output, and `collect_body ~limit` for explicitly bounded
collection. `serve_connections ~max_connections` limits admitted transports.
The caller owns routing, listener/backlog configuration, and TLS.

The installed-consumer matrix executes native and bytecode examples with the
opposite runtime unavailable. See [adapter contracts](docs/adapters.md).

## Interop and performance

`mise run setup:nginx` builds a checksum-pinned local reference. `mise run interop`
checks both adapters directly and through Nginx with buffering on/off. `mise run
performance` checks streaming queue bounds and records advisory timing, allocation
and mixed-load RSS. See [scope and limitations](docs/interop-performance.md).

## Release status

All five production packages are implemented. Release approval remains gated by
source-matched evidence. See [release tooling and remaining gates](docs/release.md)
and [private vulnerability reporting](SECURITY.md).

```sh
python3 tools/coverage.py
python3 tools/mutations.py
python3 tools/campaign.py --seconds 30
python3 tools/release.py
```

Coverage uses its own development dependency lock, also on OCaml 5.5.0. Normal
production builds require no coverage runtime. `tools/dune-pkg pkg lock` refreshes
`dune.lock`; the coverage workspace explicitly selects `coverage.lock`.
