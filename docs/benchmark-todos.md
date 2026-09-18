# Measurement backlog

Current tools and methodology: [benchmarks](benchmarks.md) and
[load testing](load-testing.md). Current evidence and blockers: [status](status.md).
This is an experiment backlog, not a required package roadmap.

## Highest-value remaining work

- Resolve or bound the [runtime/socket profiling hang](profiling-hang.md) before
  treating the long endpoint profile as reliable acceptance.
- Establish reserved-host, alternating baseline/candidate runs and reviewed
  workload-specific time, memory and latency budgets. Record power/CPU/OS metadata.
- Separate load generation from the server for publishable capacity measurements;
  account for generator saturation and intended versus actual arrival rate.
- Measure peak application-held bodies and native/per-connection memory alongside
  heap, queue and descriptor counts.

## Equivalent-work comparisons

- Add client uploads and full client/server pairs; align Expect/early-final policy
  before assigning cross-library ratios.
- Separate head/setup cost from steady transfer, sweep public buffer sizes, and
  compare whole-message APIs with explicit validation-policy differences.
- Extend body/trailer/EOF/handoff and adverse-peer comparisons only when each
  library has a comparable public contract; retain exclusions otherwise.
- Profile raw-head validation and repeated field scans rather than attributing a
  timing gap to validation without evidence.
- Refine router experiments to parse once and bound fallback construction while
  preserving declaration order, raw paths and ordered Allow results.
- Add Lwt endpoint benchmark parity when prioritized; correctness parity remains
  required. Runtime/framework comparisons need equivalent handlers and limits.
- Measure observation-hook overhead and mixed workloads with bounded password work.

Every new lane needs a stated ownership/input contract, independent result checks,
bounded execution, raw samples, units and explicit exclusions. Benchmark-only
optimizations enter production only after behavioral and measured tradeoffs support
them. Earlier completed experiments are in [the archived results](archive/benchmark-results-2026-09-11.md).
