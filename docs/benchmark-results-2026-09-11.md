# Benchmark follow-up results — 2026-09-11

Scope: the five proposed follow-ups (profile bodies, add writers/exchanges,
compare ownership models, refine router indexing, improve measurement) plus
persisting findings and remaining work. OCaml 5.5.0, pinned dependencies, native
release builds on the local macOS ARM64 host. Commands and contracts are in
[benchmarks.md](benchmarks.md); unfinished coverage is in
[benchmark-todos.md](benchmark-todos.md). No production router or codec changed.

## Small-chunk diagnostics

For a 65,536-byte POST body in 17-byte HTTP chunks, arriving in 16,384-byte
transport fragments, all three implementations delivered 3,859 data events.
Http-kit required 3,863 input calls; httpaf/httpun required eight. These are
public API/driver differences, not different payloads. Transport boundaries can
split an HTTP chunk, which explains why event count exceeds wire chunk count.

| Implementation | Owned-scan allocation/op | Borrowed-scan allocation/op | Collect allocation/op | Owned process peak RSS |
| --- | ---: | ---: | ---: | ---: |
| http-kit | 5,782,820 B | 5,782,820 B | 6,033,604 B | 7,241,728 B |
| httpaf | 39,420,572 B | 39,297,172 B | 39,671,356 B | 8,339,456 B |
| httpun | 39,298,156 B | 39,174,756 B | 39,548,940 B | 8,323,072 B |

Removing the upstream ownership copies saves 123,400 bytes/op, only about 0.3%
of their allocation in this small-chunk case. It cannot explain most of the
allocation difference. Both upstream stack samples are dominated by
`Faraday.map_to_list` and its mapping closure. Their reader code asks
`Faraday.operation` for queued slices before each callback; the samples support
investigating repeated queue materialization as a primary hotspot. This is
workload-specific evidence, not a general library ranking or a vulnerability.

Http-kit's hottest sampled leaf was the benchmark payload checker, followed by
the codec state loop, runtime mutation work, engine settling and chunk-line
handling. Optimizing only payload copying would miss other significant work.
The benchmark deliberately checks every byte, so these are not parser-only
profiles. No library optimization was applied from one stack sample.

The diagnostic process retains an 88,736-byte fixture Bigarray and a string wire
representation. After cleanup/full collection it reports roughly 26,675 live
OCaml words across modes; this is the whole process heap with fixtures, not a
peak live body. OS RSS includes runtime and allocator retention. Cumulative
allocation of 39 MB does not imply a 39 MB resident connection.

Raw diagnostic source hash:
`dd673aaa9270b7ef668ba8485180d16ed0b7e215f73f7dc98e1bbdd2d0628474`.
Retained directory: `_artifacts/body-profiles/20260911T072845Z-lykgfmcm/`.
Nine uninstrumented diagnostic processes and three separate one-second macOS
stack samples completed. Their single-process timings are not used for ranking.

## Ownership measurements and timing quality

The focused 54-case body run used five processes and a 50 ms calibration target:
`_artifacts/benchmarks/20260911T072625Z-ibeu37xx/`. Forty-six cases still exceeded
10% CV. For the 64 KiB fixed-length POST, owned allocation was approximately
79 KB (kit), 145 KB (httpaf), and 80 KB (httpun); borrowed consumption reduced the
upstream values to approximately 79 KB and 14 KB. Ownership costs matter much
more for this contiguous-body case than for thousands of tiny chunks.

Http-kit exposes owned Data in both scan modes. A borrowed-scan comparison does
not demonstrate a borrowed kit API. Collection costs include chunk retention,
list processing and final concatenation.

Longer batches did not establish quiet hardware. The runner now retains actual
and base iterations separately, descriptive bootstrap intervals, short-batch
labels, noise labels and load observations. Do not assign regression budgets or
rank close timings from these runs. Reserved-host repeats and reviewed budgets
remain outstanding.

## Correctness and scope

The combined external smoke passed **844 cases in three fresh processes**;
16 receive-only framing groups remain explicit exclusions. The new complete
server exchange lane passed **108 cases**, including chunked uploads with
one-byte input and fully drained responses. That demonstrates completion for
these driven exchanges; it does not erase the receive-only boundary distinction.

The internal smoke passed **128 cases in three processes**, including four new
100 Continue/early-final policy cases. The response oracle rejects wrong payload,
wrong requested framing, trailing bytes and extra responses. Both router
prototypes pass 12,024 reference-equivalence queries each, plus workload checks.

- External smoke: `_artifacts/benchmarks/20260911T073418Z-o5i2nb65/`.
- Internal smoke: `_artifacts/benchmarks/20260911T073541Z-paq0xvui/`.
- Full repository validation passed: builds, odoc, deterministic/property suites,
  harness CLI, installed consumers, and Eio/Lwt routing/middleware checks.
- Report integrity tests cover calibrated denominators, durations, noise/interval
  summaries and comparison/exclusion validation.

Full client/server pairs, cross-library Expect policies, body buffer sweeps,
peak application-held bodies, concurrent runtime latency, and release soak gates
remain on the backlog. The deeper index still reparses a target through singleton
reference tables; its construction and lookup tradeoffs require measurement.

## Deeper router index

The 84 selected 1,000-route cases completed five calibrated processes (50 ms
batch target): `_artifacts/benchmarks/20260911T073718Z-b9tidhua/`. Eighty cases
exceeded 10% CV. Fourteen had at least one retained batch below its target;
with short-batch precedence the quality labels are 67 noisy, 14 short, and three
low-observed-variation. Recorded one-minute load averages ranged from about 7.5
to 13.6. This measures host conditions, not a diagnosis of their cause.

Illustrative medians below are advisory; allocation and structural differences
are more useful than close timing comparisons here.

| 1,000-route construction | Reference time | First-prefix time | Deep-prefix time | Reference allocation | First-prefix allocation | Deep-prefix allocation |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Distinct | 38 µs | 10.97 ms | 1.10 ms | 32 KB | 894 KB | 966 KB |
| Shared `/api` | 32 µs | 97 µs | 1.15 ms | 32 KB | 88 KB | 982 KB |
| Fallback-heavy | 36 µs | 14.56 ms | 0.97 ms | 32 KB | 5,846 KB | 893 KB |
| Application-shaped | 41 µs | 98 µs | 1.25 ms | 32 KB | 88 KB | 924 KB |

The deep index stores 1,000 route slots for the fallback-heavy fixture instead
of 91,000. Its node count is bounded by declared literal prefix segments. It
avoids scanning all definitions for every distinct prefix, but trie nodes and
singleton reference tables still cost much more than a plain route array. It
also uses more allocation than the first-prefix index for shared-prefix tables.

For a late shared-prefix match the observed medians were 22.73 µs (reference),
26.53 µs (first-prefix) and 0.98 µs (deep-prefix): only the deeper structure can
narrow this fixture past `/api`. Early matches still pay indexing overhead.

Fallback-heavy late lookup allocation is **25,464 B** in the deep prototype
versus **5,104 B** in the reference and **5,184 B** in the first-prefix prototype.
The deep prototype calls the public matcher separately for candidates, repeating
target parsing and allocations. Its observed 20.47 µs median versus 16.81 µs for
the reference does not establish a speed improvement. Hot-route batches likewise
show why late-match-only figures are insufficient.

Decision: retain both experiments and the reference matcher; do not ship either
index unchanged. A next prototype should parse once and merge bounded candidate
streams while preserving declaration order and Allow ordering. It must retain
construction bounds and prove behavior against the reference before adoption.
