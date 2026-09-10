# http-kit

An OCaml HTTP toolkit being built from independently usable primitives, with native Eio and Lwt adapters planned above a sans-I/O engine.

**Current scope: M0–M1 development harness. There is no HTTP implementation yet.** Passing tests validate the synthetic harness and its fault detectors, not HTTP conformance or production security.

The [full design and test plan](docs/test-harness-plan.md) describes later work. The [harness contract](docs/harness-contract.md) explains exactly what the current subject models.

## Setup

Prerequisites: a C build toolchain, Python 3, Git, and either Dune 3.24.1 or opam to bootstrap it. **Dune package management owns the project compiler and dependencies.** Setup copies the pinned Dune executable into `.toolchain/bin/`; if necessary, it uses a project-local opam switch solely to build Dune. Existing switches and shell profiles are untouched.

```sh
python3 tools/bootstrap.py 5.5.0
python3 tools/bootstrap.py 5.2.1
tools/harness doctor
tools/harness run --tier fast
```

Use `HARNESS_COMPILER=5.2.1 tools/harness ...` for the minimum compiler; the default is 5.5.0. Dependencies are declared in `dune-project`; the `.opam` file is generated. `dune.lock/` and `dune.5.2.lock/` record the complete compiler/dependency solutions, source checksums, and platform-specific actions for Linux and macOS on x86_64 and arm64. Keep both directories in version control. The package is development-only; production libraries will have separate dependency closures.

Both workspace files explicitly enable package management. Regular setup and CI consume the existing locks; they never refresh dependency versions. The wrapper rejects a missing lock rather than silently resolving a new one. To deliberately update dependencies, edit `dune-project` (or the repository revision in both workspace files), then run:

```sh
tools/dune-pkg pkg lock
HARNESS_COMPILER=5.2.1 tools/dune-pkg pkg lock dune.5.2.lock
tools/dune-pkg pkg validate-lockdir
HARNESS_COMPILER=5.2.1 tools/dune-pkg pkg validate-lockdir dune.5.2.lock
tools/dune-pkg build @opam --auto-promote
```

Review the lock diffs and rerun both compiler validations and fuzz smoke. The wrapper selects Dune 3.24.1, a project-local cache, and the appropriate workspace/build directory. With that version installed, plain `dune build` also uses the default lock. See [Dune's locking documentation](https://dune.readthedocs.io/en/latest/tutorials/dune-package-management/locking.html).

The workspace pins both opam-repository and Dune's official compatibility overlay. Both locks select `ocamlfind.1.9.8+dune`, whose relocatable configuration avoids temporary sandbox paths in Topkg builds. This is a solver constraint; generated lock files are never patched by hand.

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
python3 tools/evidence.py validate 5.2.1
python3 tools/evidence.py validate 5.5.0
python3 tools/fuzz-smoke.py
tools/harness readiness --milestone M0
```

Compiler validation builds and runs deterministic/property tests plus actual CLI tests. Fuzz validation builds pinned AFL++, verifies different OCaml coverage maps, finds a planted fault, replays it in an uninstrumented executable, and runs Crowbar against the bounded scenario decoder and synthetic model. First-party code is instrumented; no third-party coverage claim is made.

The fuzzer uses SysV shared memory. A restrictive macOS sandbox may prevent allocation; that is an infrastructure failure, not a passing smoke test. Run it in a suitable local environment or use the Linux CI job. No system `sysctl` settings are modified by the scripts.

M0 readiness requires source-matched evidence from both compilers and the fuzz smoke. Editing implementation, tests, toolchain, workspace, or lock files invalidates prior evidence. Reports identify the selected lock and its packages. M1 readiness executes its own self-tests. Neither gate asserts that remote CI or production HTTP work is complete.

The CI workflow checks Linux on both compilers and macOS on 5.5, with a separate Linux instrumentation job. It is configured in the repository; it has not run merely because a local validation passed.

## Next boundary

After reviewing this harness, M2 adds validated HTTP value types and standalone consumer tests. Codecs, client/server engines, runtime adapters, protocol fuzzing, and timing benchmarks remain pending.
