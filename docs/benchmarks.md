# Benchmarks

Use these tools to measure primitive costs and compare equivalent workloads.
For HTTP endpoints, overload and adverse clients, use [load testing](load-testing.md).
Timings on shared hosts are advisory; correctness and resource bounds are separate
checks. See [status](status.md) for accepted historical evidence and open issues.

## Run a measurement

```sh
mise run bench
mise run bench:router
mise run bench:parsers
tools/dev bench --quick --samples 3
tools/dev bench --family router --samples 10 --seed 42
```

Other families are `core`, `middleware` and `engine`. The runner uses locked
OCaml 5.5.0, a native release build in `_build-bench-5.5.0`, and fresh sample
processes. It clears inherited runtime/compiler tuning and instrumentation.
Do not run CPU-heavy validation alongside a timing experiment.

Use `tools/dune-pkg exec -- bench/suite_bench.exe --list` to inspect the catalog. `--case` selects a substring; an external
comparison must retain every implementation in the selected group. Listing does
not run connection preflight. Selected body/exchange fixtures are prepared before
measurement, and incomplete or invalid groups fail instead of disappearing.

For calibrated samples:

```sh
tools/dev bench --external --family body \
  --case bytes-65536/step-16384/immediate --min-ms 50 --samples 5
```

`--min-ms` doubles the batch toward the requested duration, up to ten million
iterations. It cannot combine with `--quick`. A retained batch that falls short
is marked `short-batch`. Each process has a selection-dependent timeout with a
600-second floor and 12-hour cap; a partial run cannot produce PASS.

## What is measured

| Family | Main work |
| --- | --- |
| Core | Checked target/header construction, updates and lookup |
| Router | Pattern/table construction and declaration-ordered lookup at several table sizes |
| HTTP/1 | Head/body parsing and encoding, framing, fragmentation and rejection |
| Middleware | Basic, Context and Transition composition; guard outcomes |
| Engine | Exchange lifecycle, output acknowledgement, Expect and early-final behavior |

Every timed operation checks its result. Setup stays outside timing unless
construction is the measured operation. Decoder/engine construction, framing,
copies and payload checks remain inside the relevant workload. Input fragment
size differs from the codec's per-call work budget.

The production router remains a bounded ordered array scan. Benchmark-only prefix
indexes do not change its semantics or API. See [routing](routing.md).

## External comparisons

```sh
mise run bench:compare
mise run bench:bodies
mise run bench:exchanges
mise run bench:router-experiment
tools/dev bench --external --family http1 --quick --samples 3
```

| Lane | Comparison and limits |
| --- | --- |
| Routing | httpkit and Routes 2.0.0 through their public APIs; valid unambiguous GET paths only. Method dispatch, precedence, typed captures and invalid targets are not equivalent tasks. |
| Raw heads | httpkit, http/af 0.7.1 and httpun 0.2.0; the upstream low-level parsers do less policy/limit validation than httpkit. Raw parsing speed is not validated-message speed. |
| Body readers | Public connection APIs with fixed/chunked/close-delimited bodies, fragmentation and deferred reads. Includes head/connection setup; not an isolated body parser or full exchange. |
| Writers/exchanges | Public response writers and complete server exchanges, partial output and eight-message pipelines. Includes setup, adaptation, copying and independent wire checks. |
| Router experiments | Original prefix and deeper-prefix indexes against the reference matcher; includes fallback storage, construction cost and hot-route workloads. Neither is a production replacement. |

Dependencies and checksums are pinned in both Dune locks and belong only to the
developer harness. Versions, workload identities and exclusions are retained in
reports. The executable catalog is authoritative for case counts.

Body ownership is explicit. **Owned scan** copies upstream borrowed buffers to
match httpkit's owned strings. **Borrowed scan** checks upstream buffers in their
callback; httpkit still returns owned data. **Collect** retains chunks and includes
concatenation. These are different tasks, not interchangeable zero-copy claims.

Fixtures include binary bytes and literal expected content. Prefix accounting,
framing completion, suffix preservation and response identity are checked. Receive-
only groups where the selected driver stops before consuming framing are excluded
for every library, with observed counts retained. An exclusion is not a vulnerability
finding or permission to compare partial work with complete work.

Pipeline requests use ordinal targets and matching response headers. Reorder,
duplicate and omission controls test the oracle. Input readiness controls prevent
paused readers from silently changing the configured transport fragmentation.
Changed oracle/driver work requires a new baseline.

## Reports and comparisons

Each run writes `_artifacts/benchmarks/<run>/`:

- `sample-N.json`: raw timings, actual iterations, warmup, allocations and GC counts.
- `report.json`: catalog, raw samples, source/workload/toolchain identities, host,
  seeds, exclusions and aggregates.
- `report.md`: medians, ranges, variation, allocations and requested comparisons.

Time summaries describe **independent process means**, not per-request p50/p99.
The 2,000-resample bootstrap interval is descriptive; with few samples it is coarse.
CV above 10% or short batches make a case unsuitable for ranking. Low variation
alone does not establish controlled hardware, power or thermal conditions.

Allocation is cumulative OCaml heap allocation, including checks and measurement
overhead. It excludes external Bigarray/native storage and is not retained heap
or RSS. Byte throughput uses the workload's declared input/payload denominator.
External time ratios are `other/httpkit`: below one means the other library was
faster for that workload. There is no pooled winner or security score.

Compare an unchanged workload on the same machine:

```sh
tools/dev bench --family router --samples 10
tools/dev bench --family router --samples 10 \
  --baseline _artifacts/benchmarks/BASELINE-RUN/report.json
```

The validator rejects incompatible compiler/profile, workload/toolchain hash,
host, seeds, sample count, quick mode, selection or catalog. It recomputes summaries
and exclusions from raw samples. Production source hashes may differ; benchmark
or lock changes need a fresh baseline. Positive deltas mean slower execution or
more allocation. Zero-allocation baselines use an absolute delta.

For optimization decisions, alternate baseline/candidate runs on controlled
hardware. Preserve failed/noisy runs. Repeating until a result passes or comparing
incompatible ownership policies does not establish improvement.

## Diagnostics and history

`tools/dev profile-bodies` records event/read counts, post-cleanup live heap,
fixture storage and OS RSS for the small-chunk workload. `--stack` adds separate
macOS sampling processes whose timings do not count as ordinary measurements.
These memory quantities describe different owners and must not be added into a
fabricated per-connection figure.

[September 11 results](archive/benchmark-results-2026-09-11.md) retain measurements
and invalidated comparisons. [Measurement backlog](benchmark-todos.md) lists useful
remaining experiments. [Release policy](release.md) owns acceptance requirements.
