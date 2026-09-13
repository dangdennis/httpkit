# Developer tooling

The development harness is implemented in OCaml. `tools/dev` builds the CLI with
our pinned Dune environment, then executes it outside Dune so its child builds can
run independently. Production libraries do not depend on this tooling.

Two small POSIX shell entry points cover bootstrapping: `tools/bootstrap` installs
the pinned compiler/Dune before OCaml tooling exists, and `tools/dune-pkg` selects
the committed workspace and lock. No additional scripting-language runtime is
required. Git, opam/mise, native build tools, curl, and the selected database or
fuzzer remain external executables.

| Task | Command |
| --- | --- |
| Build, docs, regressions and installed consumers | `tools/dev validate` |
| Tooling unit controls | `tools/dev selftest` |
| Benchmark report controls | `tools/dev bench-test` |
| Benchmark preflight/selection | `tools/dev bench-selection-test` |
| Coordinator/resource controls | `tools/dev coordinator-test` |
| Application/database failed-start cleanup | `tools/dev runner-test` |
| Installed consumers | `tools/dev consumer core` (also protocol, adapter, middleware, router, framework, extensions) |
| Framework HTTP integration | `tools/dev framework-test` |
| Both routing examples | `tools/dev routing-test` |
| Disposable PostgreSQL/SQLite | `tools/dev databases` |
| Point coverage | `tools/dev coverage` (also framework, extensions) |
| Compiled mutation checks | `tools/dev mutations` (also framework) |
| Direct/Nginx interoperability | `tools/dev interop` |
| Queue bounds and mixed adapter loads | `tools/dev performance` |
| Repeated benchmarks | `tools/dev bench --quick --samples 3` |
| Body resource diagnostics | `tools/dev profile-bodies` |
| Framework load | `tools/dev framework-load --mode smoke --database sqlite` |
| Personal Eio load | `tools/dev personal-load --mode smoke` |
| Framework acceptance, including long runs | `tools/dev framework-validate --long` |
| Personal acceptance excluding AFL | `tools/dev personal-validate --long --skip-afl` |
| Optional fuzz instrumentation checks | `tools/dev fuzz-smoke` |
| Optional fuzz campaigns | `tools/dev fuzz --seconds 30` |
| Optional historical timeout investigation | `tools/dev triage-timeout` |
| Read-only release assessment | `tools/dev release` |
| Source provenance | `tools/dev fingerprint` |

Fuzz commands are retained but are not run by `validate` or framework acceptance.
AFL remains deferred for this continuation. Personal acceptance retains an
explicit `--skip-afl` option. The source/workload hash checks reject measurements
if inputs change during a run. Old acceptance artifacts retain their original
hashes and are not relabeled as current evidence.

The OCaml network harness uses an independent http/af parser, plus curl for a
second client. HEAD responses use the head parser without reading a body;
streaming load clients retain at most one 8 KiB payload chunk at a time and verify
payloads incrementally. Load workers use separate connections, join on failure,
and retain bounded latency histograms. Process deadlines use monotonic time;
owned subprocess groups are stopped and reaped when a scope fails.

Benchmark bootstrap intervals now use seeded OCaml resampling. Workload hashes
include the new implementation, so historical reports cannot silently become
compatible baselines. Timings remain advisory on shared machines. Durable
acceptance logs remain authoritative if a progress terminal disconnects.
