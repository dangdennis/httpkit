# Benchmarking the primitives

The pure router is implemented in `httpkit-router` and shared by both native
Eio and Lwt example servers. Its bounded, declaration-ordered array scan supports
literal segments, named parameters, final wildcards and method mismatch results.
It is not a trie; typed capture conversion and reverse URL generation are not
implemented. See [routing semantics](routing.md).

The default suite measures our own implementations across workloads. The
external suite below compares a common subset against pinned OCaml libraries,
with explicit limits on what can be inferred from differing API contracts.

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
tools/dev bench --quick --samples 3

# More independent samples of one family:
tools/dev bench --family router --samples 10 --seed 42
```

The runner builds a native executable with `--profile=release` in
`_build-bench-5.5.0`, separate from correctness, coverage and AFL builds. It clears
inherited OCaml runtime/compiler tuning and AFL/Bisect instrumentation variables.
The first build can take longer while locked dependencies are built for this
profile. The OCaml developer CLI builds, launches and aggregates separate benchmark
processes; timed primitive work excludes orchestration and socket overhead.

## Workload inventory

| Family | Cases | What is varied |
| --- | ---: | --- |
| Core | 15 | Valid targets and invalid final bytes at 16/256/8192 bytes; header construction, append and get-all at 1/10/100 fields |
| Router | 27 | Literal/parameter/wildcard pattern construction; table compilation and first/middle/last/missing/method lookup at 10/100/1000 routes; six path/capture shapes |
| HTTP/1 | 56 | Request/response heads at 0/10/90 extra fields; fixed/chunked-with-trailers/close-delimited bodies at 64/4096/65536 bytes; 1/64/16384-byte input fragments; invalid version/field and truncated EOF; request/response head and fixed/chunked body encoding |
| Middleware | 14 | Basic, Context and Transition at depth 0/1/5/20; Transition guard acceptance and rejection |
| Engine | 16 | Server lifecycle at 0/4096/65536 body bytes with 1/997/16384-byte acknowledgements; client lifecycle receiving 4096 bytes in 1/64/16384-byte fragments; Expect/early-final policy at 4096/16384 bytes |

Total: **128 cases**. The executable exposes its catalog through `--list`; the
runner requires that exact catalog, iteration counts and byte counts in every
sample. Unknown families, invalid measurements, duplicate/missing cases and wrong
compiler versions fail the run. CI gates successful execution and report validity,
not timing thresholds. `tools/dev bench-test` checks report integrity
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
tools/dev bench --family router --samples 10
# Substitute the report.json path printed by that run below.
tools/dev bench --family router --samples 10 \
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

Useful follow-ons are more external libraries and public connection/body APIs,
production route/request distributions, concurrent routed endpoint latency, and a reserved
runner with paired baselines. Add workloads when new primitives land, keeping
fixture preparation separate and an explicit result oracle in every timed case.

## External-library comparisons

```sh
mise run bench:compare
tools/dev bench --external --family router
tools/dev bench --external --family http1
tools/dev bench --external --quick --samples 3
```

`--external` selects a separate catalog; it does not append to or reuse the
default suite's measurements. All implementations run in each process, with the
same iteration count and byte count per comparable workload and shuffled case
order. Five process samples are the default. Linux/macOS CI runs the short form.

| Lane | Libraries | Common workloads | Cases |
| --- | --- | --- | ---: |
| Routing | httpkit, Routes 2.0.0 | Table construction plus one checked lookup; first/middle/last/missing lookup at 10/100/1000 routes; literal, parameter, wildcard, empty wildcard, raw encoded capture with query | 40 |
| HTTP heads | httpkit, http/af 0.7.1, httpun 0.2.0 | Request/response heads with 0/10/90 extra fields, fragmented at 1/64/16384 bytes | 54 |

This head/router subset has **94 cases forming 56 pairwise comparisons**.
The default external command also runs the body and router-experiment lanes below. Names, versions and source
checksums are locked by Dune in both existing locks. Only `httpkit-harness`
depends on these libraries; production package dependencies are unchanged.
Reports retain versions of the comparison libraries and Angstrom, Bigstringaf
and Faraday as well as the full lock/workload hash. Benchmark and dependency
changes require fresh baselines.

Routing uses the published [Routes 2.0.0 API](https://github.com/anuragsoni/routes/blob/2.0.0/src/routes.mli).
Its trie and our array scan are exercised through their own APIs. Route pattern
construction and target validation are outside lookup timing. Table construction
starts with prepared route definitions and includes one identical checked lookup.
Both lookup adapters produce an endpoint number and string capture; adapting
those results and checking them is timed. Routes wildcard strings include a leading
slash; the adapter removes it to produce the common capture representation, and
that extra copy is timed. Routes provides typed captures and URL
generation beyond this measured subset; our API includes HTTP method dispatch
and explicit resource limits. Those features are not interchangeable.

All compared routing paths are valid, unambiguous GET paths. There is no added
method shim around Routes. HTTP method mismatch/Allow, overlapping-route
precedence, trailing-slash redirects, integer capture conversion and invalid or
over-limit targets are excluded. Raw `%2F` captures and query exclusion are
checked for both implementations. Keep their broader behavior in the dedicated
correctness tests rather than treating timing as conformance evidence.

Head parsing uses the version-pinned
[http/af low-level parsers](https://github.com/inhabitedtype/httpaf/blob/0.7.1/lib/httpaf.mli)
and [httpun low-level parsers](https://github.com/anmonteiro/httpun/blob/0.2.0/lib/httpun.mli)
through `Angstrom.Buffered`. These exported `*_private.Parse` entry points are
benchmark-only interfaces and may change across versions. The comparison checks
HTTP/1.1, method/target or status, every field/value and complete input consumption.
All inputs have `Content-Length: 0`; requests also have Host. Extra fields have
unique names. httpkit additionally checks its returned zero-length framing.

**Validation work is not equivalent.** Our codec applies authority, framing and
resource-limit checks before returning a head. The upstream raw parsers have a
smaller responsibility; their surrounding connection implementations add policy
that is not timed here. A faster raw parse is not evidence that the same validated
operation is faster, nor that a library is more or less secure. This raw-head subset excludes bodies; the public body lane below adds them.
Meaningful trailers, malformed input and complete server throughput still need
separate comparisons.

The pinned http/af raw parser exposes `Headers.to_list` in reverse wire order.
Its expected list is prepared in that order outside timing; the other two are
checked in wire order. Since names are unique, these workloads do not depend on
duplicate-header ordering. This is a property of the selected low-level entry
point, not a claim about all public server behavior.

Input fragments are allocated once outside timing for all three parsers. Parser
instance creation and API-required buffering/copying remain timed; Angstrom uses
its default 4 KiB initial buffer. Field-result adaptation and equality checks are
also timed. Allocated bytes describe the OCaml GC heap; they omit externally
allocated Bigarray payloads, so they cannot establish total-memory superiority.

The report begins with per-workload medians, allocation and **other/httpkit time
ratios**, calculated within each process before taking their median. Below 1
means the other library was faster on that workload. Raw ratios and measurements
are retained, and incomplete comparison groups fail. There is no pooled score,
automatic winner or security verdict. `--baseline` still compares two compatible
runs, including external mode in its configuration checks.

## Public body readers

```sh
mise run bench:bodies
tools/dev bench --external --family body --quick --samples 3
```

The initial owned-body lane generates 128 common workloads, each attempted against httpkit,
httpaf and httpun: 384 potential timed cases. Preflight currently excludes 16
whole workload groups because httpaf can report body EOF before consuming the
last framing bytes and then pause reads in this driver. The remaining 112 groups
produce **336 timed cases**. Every group is attempted before timing, and all
observations/exclusions are retained in the catalog and every sample. The report
rejects exclusions that overlap timed groups or differ across processes. Unexpected
errors, incorrect payloads and incomplete reference-engine behavior fail the run.

This is a receive-side public-connection comparison, including head parsing,
connection setup and cleanup. It is not an isolated body-parser timer or a full
request/response round trip: servers do not send a response, and client request
output is constructed but not drained. Public buffering and validation defaults
still differ. Reuse, outgoing writes and complete exchanges remain in the TODO plan.

| Axis | Implemented variants |
| --- | --- |
| Direction | Incoming POST request; incoming 200 response |
| Framing | Content-Length; chunked with 1/17/8192-byte wire chunks; response close-delimited |
| Body bytes | 0, 64, 4096, 65536, 1048576 |
| Transport | 1, 64 or 16384-byte arrivals; repeating 1/7/64/3/4096/17/8192-byte irregular arrivals |
| Data | Deterministic binary pattern including NUL and high bytes |
| Consumer | Owned-string scan; owned chunk collection followed by exact concatenation check |
| Scheduling | Immediate read rearming; deferred rearming/polling on every second driver tick |

The matrix is deliberately selected, not a Cartesian product. The base grid uses
64/16384-byte arrivals and 17/8192-byte wire chunks across all sizes. One-byte
arrivals and one-byte wire chunks are restricted to 64/4096-byte bodies. Irregular
arrivals, collection and deferred consumption use 4096/65536-byte bodies with
fixed framing, 17-byte chunks and response close-delimiting. Deferred ticks are
logical scheduling steps, not wall-clock delays or a socket-latency simulation.

Fixtures contain both string and Bigarray representations outside timing. Input
suffixes remain with the caller. A new arrival is exposed when the available
window is exhausted or the parser needs more input; draining an existing window
does not silently add a new transport fragment. Every returned prefix is checked.
Only close-delimited bodies receive transport EOF. Fixed/chunked completion must
come from framing. Payload order, every byte, one head, one body completion and
complete wire consumption are required. The engine's empty trailer event is
checked; meaningful trailer fields are a future separate lane.

Upstream callbacks expose borrowed Bigarrays. The adapter copies their slices to
owned strings before checking or collecting them, matching engine Data ownership.
Collection retains chunks until EOF and includes final concatenation. No timing
claim about zero-copy/borrowed consumption is made. Per-library buffer sizes,
callback/event grouping and API glue remain part of the measured workload.

The observed early-body-EOF cases are excluded for **all three implementations**
so partial framing cannot earn a faster result. Their JSON records include the
implementation, consumed prefix and total wire size. This is an observation about
this receive-only driver and selected versions, not a security verdict or a claim
that the libraries cannot finish an exchange when a response is sent. Public
exchange/pipeline experiments should revisit that boundary.

Large-body cases have fewer iterations to bound execution time (1–50 normally;
quick mode divides by ten, minimum one). Several large cases therefore need more
samples/longer measurements on a controlled runner before small timing differences
are actionable. GC allocation omits Bigarray payloads, and the materialized fixture
set is not a memory-bounded network-streaming workload.

## Router candidate-index experiment

```sh
mise run bench:router-experiment
```

`bench/suite_router_experiment.ml` is benchmark-only code. No production router
behavior or API has changed. It selects candidates by the first literal segment,
preserves their original order (including general parameter/wildcard routes), and
uses the existing router for final matching, methods, Allow results and limits.
Every sample first checks 12,024 queries against the reference: deterministic
boundary cases and seeded overlapping route tables across GET/POST/HEAD, including
raw captures, queries, root/repeated slashes, unsupported targets and byte/segment
limits. These checks are evidence for this prototype, not proof of a production
replacement.

The initial prefix experiment had **108 cases**: two implementations, three table sizes (10/100/1000),
three shapes (distinct first segments, one shared `/api` prefix, 10% general
fallback routes), and construction plus early/middle/last/missing/method lookup.
All lookups check the complete outcome against the reference. Early lookup targets
the first specific route after a possible general route. Pattern construction is
outside construction timing; index construction includes a reference compile to
retain its route-count validation.

This prototype deliberately exposes a tradeoff: building buckets scans the route
list for every distinct literal prefix. General routes are duplicated in every
bucket. A 1,000-route fixture with 100 general routes and 900 literal prefixes has
**91,000 candidate slots**, versus 1,000 slots for the distinct/shared fixtures.
These are reference slots, not duplicated payload objects or measured retained
heap bytes. A production design needs a bound or a shared fallback representation.

The experiment tests a hypothesis rather than claiming a general speedup:
distinct prefixes can reduce search; shared prefixes still scan; fallback-heavy
tables spend additional construction work and storage. Profile and compare the
full tradeoff before selecting a production data structure.

The persistent [benchmark TODO plan](benchmark-todos.md) tracks remaining parser
profiling, body writers, full exchanges, runtime workloads and measurement gates.

## Follow-up experiments: ownership, exchanges, deeper indexing

The external catalog now includes 390 body cases (the original 336 plus 54
borrowed-consumption cases), 108 writer/exchange cases, 252 router experiment
cases, and the original 94 head/Routes cases: **844 external cases**. The internal
suite adds four kit-only Expect/early-final policy cases, for **128 cases**.

```sh
mise run bench:exchanges
mise run bench:profile-bodies
tools/dev profile-bodies --stack  # macOS, separate instrumented processes
tools/dev bench --external --family body \
  --case bytes-65536/step-16384/immediate --min-ms 50 --samples 5
tools/dev bench --external --family router-experiment \
  --case /1000 --min-ms 50 --samples 5
```

The borrowed-scan lane checks upstream Bigarray slices inside their callback
without retaining them. httpkit still supplies owned immutable Data: this lane
compares the APIs' available ownership models, not equivalent zero-copy
implementations. Owned-scan and collect retain their original copy semantics.
All modes count payload events; the small counter overhead is included.

The `exchange` family drives public server readers and streaming response writers.
The writer variant uses an empty incoming request; the full exchange variant
checks both incoming and outgoing binary payloads. Fixed/chunked framing,
0/4096/65536-byte payloads, empty writes, writer finalization, 1/997/16384-byte
output acknowledgements, one-byte input fragmentation, and eight pipelined
messages are covered. Request bytes remain caller-owned until consumed; unread
fragments are extended when a ready parser needs more input. Paused readers do
not expose new arrivals; an alternating-readiness regression fixture checks that
contract. An independent codec
oracle checks every response's status, exact payload, framing, count, and absence
of trailing bytes. Re-polling output before acknowledging checks stable exposed
bytes. The timer includes setup, API adaptation, copies, output collection and
oracle work; it is not isolated serialization speed. These fixtures do not force
equal library buffer policies. Full client/server pairs, explicit backpressure
sweeps, network latency and framework handlers remain separate work.

The four internal engine policy cases verify 100 Continue upload gating and an
early final response before sending the body, at 4096/16384 bytes. These have no
cross-library ratios because policy differences need explicit alignment first.

The original prefix index remains as a comparator. The deep index stores each
route exactly once at its longest literal prefix, including shared `/api/v1`
paths. Ancestor fallback routes are merged by declaration ordinal, with the
reference matcher providing captures and ordered/deduplicated Allow semantics.
Construction visits the declared literal prefixes and has at most one node plus
the total number of literal segments; it no longer duplicates general routes in
every bucket. Maps add logarithmic lookup/insertion work. Targets pass the
reference limit checks before traversal. Singleton reference tables deliberately
reparse candidate targets: this can hurt fallback-heavy lookups and remains a
prototype tradeoff. Both indexes undergo 12,024 differential queries each, plus
fixture-specific checks. Four table shapes at 10/100/1000 routes include an
application-shaped mixed-method table and 100-lookup batches with 90% hot-route
traffic. A hot-skew operation is one batch, not one lookup. No production router
implementation changed.

## Calibrated measurements and diagnostic memory

`--min-ms` calibrates each case outside the retained timer, doubling a batch until
it reaches the requested duration, with a ten-million-iteration cap. Warmup and
calibration run the same correctness-checked operation. Raw samples retain actual
iterations and catalog base iterations separately; denominator validation uses
the actual count. This option cannot combine with `--quick`. The final measured
batch may fall short after calibration if execution conditions change, and is
explicitly marked `short-batch`. The setting and case selection participate in
baseline compatibility. `--case` is a substring filter; external selections must
retain every implementation in each comparison group.

Reports include a deterministic 2,000-resample, descriptive 95% bootstrap interval
for the median of independent process means, plus load-average observations
before/after each process. With few samples these intervals are coarse. A batch
below its duration target or a case above 10% CV is unsuitable for a performance
ranking or budget. Low observed variation alone does not establish controlled
power, thermals, scheduling or CPU isolation. This host remains unreserved;
regression budgets stay unset until reviewed, reproducible baselines exist.

`performance.ml` builds one 64 KiB, 17-byte-chunk fixture per process, captures
payload-event/read/tick counts, cumulative OCaml allocation, and live heap words
after cleanup and full collection. Its fixture Bigarray size is explicit.
`/usr/bin/time` retains OS peak RSS (macOS reports bytes; Linux `time -v` reports
KiB). RSS includes the runtime, fixture and allocator retention; post-cleanup
live words are not the peak live body or application-held body size. The owned
and borrowed fixture representations coexist and are part of this diagnostic
process's footprint. These quantities must not be added into a fabricated
per-connection memory number. `--stack` uses separate macOS `sample` processes;
their timing is excluded from ordinary measurements. Reports and raw stack/OS
resource files are retained under `_artifacts/body-profiles/`.

Retained reports are validated from raw samples before comparison. This includes
aggregate metrics, paired library comparisons and identical per-sample exclusions.
Missing or inconsistent derived fields are rejected; historical artifacts are
never silently rewritten or treated as authenticated external evidence.

Pipeline requests carry ordinal targets and responses carry matching `x-message`
headers. The oracle checks ordered association, including empty bodies, and has
reorder/duplicate/omission controls. This changes the measured workload: earlier
pipeline timings remain historical and are not compatible performance baselines.

## Selection and execution budgets

`--list` enumerates cases without running connection preflight. The runner uses
`--preflight-only` to establish eligible cases and retain framing exclusions
before sampling. Body and exchange case filters apply before preparing their
fixtures and must retain whole comparison groups. The router experiment's
independent equivalence controls run outside timed samples, not during listing.

Each sample process gets a budget based on selected case count and minimum batch
duration, with calibration/warmup allowance, a 600-second floor and a 12-hour cap.
Selections exceeding the cap fail before measurement. The budget is a timeout,
not a prediction that all cases will reach their target duration. Partial raw
samples remain diagnostic artifacts; an incomplete run does not produce PASS.

Body fixtures use named direction, framing, transport, scheduling and consumption
settings. Owned scan, borrowed scan and collection are exclusive choices. The
shared input-window helper advances arrivals only when parsing needs more bytes;
a paused runtime does not change the configured transport fragmentation.

## End-to-end application endpoint profile

```sh
tools/dev endpoint-profile --seconds 10 --repetitions 3
# Functional check of every endpoint/concurrency combination:
tools/dev endpoint-profile --seconds 0.1 --repetitions 1
```

This local OCaml runner starts the Eio framework example with no database and
measures one endpoint at a time over persistent HTTP/1.1 connections. It retains
the example's routing, request IDs, security headers and CORS middleware. The
default binary uses the ordinary development build; the report records that
profile. A supplied `--binary` has external/unverified build provenance and must
expose the same Eio/compiler/counter contract. This is an application workload,
not a minimal codec or release-optimized framework comparison.

| Endpoint | Request body | Response body / producer chunks |
| --- | --- | --- |
| GET /plaintext | Empty | 14-byte greeting |
| GET /json | Empty | 27-byte JSON object, encoded per request |
| POST /echo | 4096 bytes | Exact 4096-byte echo |
| GET /small-stream | Empty | 4096 bytes in four 1024-byte sends |
| GET /large-stream | Empty | 1 MiB in 128 8192-byte sends |

Each configuration uses concurrency 1, 4 and 8, one second of untimed warm-up,
then the requested repetitions. Payload contents and status are checked on every
operation. The report under `_artifacts/framework/endpoints-*/report.json` records
source, binary and workload hashes; lock metadata hash (full lock files also enter
the source hash); compiler, OS/architecture and available domains; throughput;
p50/p95/p99 histogram upper bounds; server allocated words/bytes per request,
minor/major collection counts and CPU time/utilization; RSS, descriptor and
connection observations; and final shutdown accounting. CPU utilization is a
percentage of one core. Allocated words are `minor_words + major_words - promoted_words`,
not an allocation-object count. Counter validation rejects decreases, invalid
word size and nonfinite values.

The test-only `/bench-stats` endpoint samples process counters without forcing GC.
Counter intervals include boundary requests and connection setup/teardown, so
allocation results have a small sampling overhead. Resource checks force GC only
outside those intervals. The client and server share a host; client byte checking,
thread scheduling, laptop load and GC can limit throughput. A short run is a
functional check, not a statistical baseline. No automatic timing threshold is
introduced. Release-profile runs, Lwt parity, richer hardware provenance, separate
load hosts, slow-client matrices and external framework comparisons remain open.
