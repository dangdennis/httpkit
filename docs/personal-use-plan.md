# Eio personal-use acceptance

Historical acceptance profile. Start new applications with the
[installation and starter guide](internal-use.md); see [status](status.md) for
completed campaigns and remaining issues. The budgets below remain historical
requirements, not claims that the current checkout has passed them.

Scope: OCaml 5.5.0, HTTP/1.1, Eio first, bounded local applications. This is a
separate acceptance profile; the public-release policy is unchanged. README stays
focused on using the packages.

## Current scope decision

The user deferred all AFL work, including campaigns and timeout investigation.
Preserve the historical request input and the new core-target timeout from the
interrupted campaign; neither is resolved. Continue all non-AFL validation and
restart the two-hour Eio soak on the updated candidate. Existing public-release
requirements remain unchanged. Use `tools/dev personal-validate --long --skip-afl`.

## Ordered work

1. Preserve the retained request timeout and its original AFL 512 MiB / 2 s
   limits. Investigation remains deferred; passing replays alone do not establish root cause.
   Refresh compiler/tests/docs/installed consumers, coverage and direct/proxy interop.
2. Add a complete Eio application with incremental uploads/downloads, routing,
   middleware, bounded admission/body/output, cancellation and graceful shutdown.
3. Exercise slow peers, EOF/reset, oversized/ambiguous input, early rejection,
   keep-alive, cancellation and shutdown. Check exact bytes and resource cleanup.
   Keep both adapters in shared-code regression validation.
4. Measure routed requests, uploads and downloads at increasing concurrency.
   Keep correctness checks and report latency, throughput and memory. Only adopt
   optimizations supported by equivalent alternating baseline/candidate runs.
5. Historical acceptance budget: 1,800 seconds per catalog fuzz target and a
   7,200-second Eio mixed-load soak. AFL remains skipped; see the active production
   roadmap for non-AFL campaign work. Preserve source hashes, corpora and failures.
   Require correct responses, no untriaged findings, bounded resources and clean
   shutdown. Smoke runs cannot substitute for these budgets.
6. Verify a separately installed Eio consumer, document measured limits and tag a
   candidate only after required evidence passes. Keep a known-good rollback ref.

The implementation agent owns code, tests and experiment execution. External
review, publication licensing and the full public release matrix remain separate.
An unexplained historical timeout stays explicitly unresolved; do not manufacture
an infrastructure classification or a clean acceptance result.

## Measurement interpretation

Use a local repeatable workload to establish a usable operating range. Host load
and client saturation can invalidate latency/throughput comparisons. No universal
requests/second target is assumed, and no prototype router optimization is adopted
without measured benefit. Resource checks distinguish engine bounds, application
retention, post-GC live heap, descriptors and process RSS. RSS need not fall to its
startup value; persistent growth after warmup must be investigated.
