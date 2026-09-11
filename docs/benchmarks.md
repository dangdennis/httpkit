# Benchmarking the primitives

The pure router is implemented in `http-kit-router` and shared by both native
Eio and Lwt example servers. Its bounded, declaration-ordered array scan supports
literal segments, named parameters, final wildcards and method mismatch results.
It is not a trie; typed capture conversion and reverse URL generation are not
implemented. See [routing semantics](routing.md).

The unified suite measures our own implementations across workloads. It does
not yet compare other libraries. Such comparisons need the same routing order,
raw-path/decoding policy, method behavior, parser strictness and resource limits
before their numbers are useful.

## Run it

Use the existing mise → opam → Dune toolchain and `dune.lock` (OCaml 5.5.0):

```sh
mise run bench
mise run bench:router
mise run bench:parsers
mise run bench:core
mise run bench:middleware
mise run bench:engine

# Short functional smoke, also run on Linux and macOS in CI:
python3 tools/benchmarks.py --quick --samples 3

# More independent samples of one family:
python3 tools/benchmarks.py --family router --samples 10 --seed 42
```

The runner builds a native executable with `--profile=release` in
`_build-bench-5.5.0`, separate from correctness, coverage and AFL builds. It clears
inherited OCaml runtime/compiler tuning and AFL/Bisect instrumentation variables.
The first build can take longer while locked dependencies are built for this
profile. Python only builds, launches and aggregates; all timed primitive work
runs inside OCaml, without Python or socket overhead.

## Workload inventory

| Family | Cases | What is varied |
| --- | ---: | --- |
| Core | 15 | Valid targets and invalid final bytes at 16/256/8192 bytes; header construction, append and get-all at 1/10/100 fields |
| Router | 27 | Literal/parameter/wildcard pattern construction; table compilation and first/middle/last/missing/method lookup at 10/100/1000 routes; six path/capture shapes |
| HTTP/1 | 56 | Request/response heads at 0/10/90 extra fields; fixed/chunked-with-trailers/close-delimited bodies at 64/4096/65536 bytes; 1/64/16384-byte input fragments; invalid version/field and truncated EOF; request/response head and fixed/chunked body encoding |
| Middleware | 14 | Basic, Context and Transition at depth 0/1/5/20; Transition guard acceptance and rejection |
| Engine | 12 | Server lifecycle at 0/4096/65536 body bytes with 1/997/16384-byte acknowledgements; client lifecycle receiving 4096 bytes in 1/64/16384-byte fragments |

Total: **124 cases**. The executable exposes its catalog through `--list`; the
runner requires that exact catalog, iteration counts and byte counts in every
sample. Unknown families, invalid measurements, duplicate/missing cases and wrong
compiler versions fail the run. CI gates successful execution and report validity,
not timing thresholds. `python3 tools/test_benchmarks.py` checks report integrity
and comparison rejection with deterministic fixtures.

Router tables, parsed body metadata, input strings and middleware chains are built
outside the timer, except in cases explicitly named `pattern`, `compile` or
`construct`. Decoder/encoder and engine instance construction is timed with the
operation. Each middleware layer performs one integer increment; these cases
measure context plumbing, not application authentication. The homogeneous
Transition chain isolates combinator overhead; compile-time guarantees for
heterogeneous transitions are covered by installed-consumer tests.

All timed operations include result checks. Parser body and engine checks inspect
payload bytes; their throughput includes that scan. Server workloads verify the
wire and enforce the 32768-byte output queue bound while retrying backpressured
sends. Their time includes lifecycle setup, framing, copying and acknowledgements.
Input fragmentation is the caller's fragment size, distinct from the codec's
unchanged 16384-byte per-operation budget. Chunked bodies include a declared
trailer; close-delimited bodies explicitly finish through EOF.

## Reports and comparisons

Each invocation creates a unique `_artifacts/benchmarks/<run>/` directory with:

- `sample-N.json`: raw per-case elapsed time, iteration/warmup counts, ns/op,
  allocated bytes/op, minor/major collection counts and bytes/op.
- `report.json`: raw samples plus the catalog, source/workload hashes, compiler,
  profile, host metadata/fingerprint, case-order seeds and aggregate results.
- `report.md`: per-case median, range, coefficient of variation (CV), allocation
  and byte throughput, plus comparison deltas when requested.

Each sample is a fresh process. Cases run in a seeded shuffled order, warm up for
up to three iterations, and start timing after a full major collection. The
normal iteration count is fixed per workload in `bench/suite_*.ml`; `--quick`
reduces it tenfold (minimum one). This is smoke coverage, especially for expensive
one-byte fragmentation cases. Keep quick and full results separate.

Time summaries are medians and ranges of **sample means**, not per-request
p50/p99 latency. CV above 10% is reported as a noise signal, not a failing gate.
Allocation comes from `Gc.allocated_bytes`, includes measurement overhead and
checks, and is not retained heap size or RSS. GC counts remain in raw samples.
Target/head throughput counts input bytes; body/engine throughput counts payload
bytes, excluding framing. Operations without a useful byte denominator have no
MiB/s value. Operations/sec is also retained in JSON.

Retain a full report before changing production code, then compare on the same
machine with the same command options:

```sh
python3 tools/benchmarks.py --family router --samples 10
# Substitute the report.json path printed by that run below.
python3 tools/benchmarks.py --family router --samples 10 \
  --baseline _artifacts/benchmarks/BASELINE-RUN/report.json
```

The runner rejects mismatched schema, compiler, profile, benchmark/toolchain hash,
host fingerprint, seeds, sample count, quick mode, family or catalog. It also
recomputes baseline summaries from their retained samples. Production source
hashes may differ—that is the purpose of comparison. Benchmark or lock changes
require a new baseline. Positive deltas mean slower execution or more allocation;
zero-allocation baselines get an absolute allocation delta without a percentage.

Host identity does not establish idle CPUs, reserved hardware, thermal stability,
frequency or power settings. For optimization decisions, keep those controlled,
alternate old/new builds, and repeat noisy results. Shared CI artifacts are useful
for workload failures and investigation, not cross-OS speed rankings or release
performance approval. Baseline deltas remain advisory; they do not close M7 gates.

## Native workloads and future additions

`mise run performance` retains the existing independent engine streaming and
Eio/Lwt loopback workloads: 64 KiB/1 MiB/16 MiB streaming, queue bounds, repeated
timing/allocation, and 200 mixed fixed/chunked requests per adapter with concurrency
four, request p50/p99 and sampled RSS. These use the existing default build profile
and a separate report; do not directly compare their times to release microbenchmarks.
See [interop and performance](interop-performance.md) for measurement limits.

The old `core_bench`, `http1_bench`, `router_bench` and `stream_bench` executables
remain for existing milestone evidence formats. They do not replace this catalog.
Security properties remain the responsibility of deterministic/property tests,
negative compile tests, fuzzing and the [manual release gates](m7-manual-checklist.md).
Fast rejection timing alone cannot establish parser safety.

Useful follow-ons are a semantically matched external-library lane, production
route/request distributions, concurrent routed endpoint latency, and a reserved
runner with paired baselines. Add workloads when new primitives land, keeping
fixture preparation separate and an explicit result oracle in every timed case.
