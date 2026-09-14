# Native generated-input campaigns

Run the existing Crowbar properties without AFL or instrumentation:

```sh
tools/dev native-fuzz --rounds 10000 --batches 3 --seed 42
tools/dev native-fuzz --target websocket --rounds 100000 --batches 10 --seed 100
```

The shared `toolchain/fuzz-targets.json` catalog currently selects 14 targets:
core values, request/response heads, chunked bodies, client/server engine,
partial writes, adapters, exchange isolation, URL, forms, router, multipart and
WebSockets. Each batch is a fresh process, using successive explicit 64-bit
seeds. `--timeout` bounds each batch's execution (default 120 seconds), including
properties that stop making progress. The runner terminates and joins timed-out
processes. A timeout is a failed investigation, never a passing shorter run.

Reports under `_artifacts/native-fuzz/run-*/` preserve source, catalog and binary
hashes, compiler, selected case, seed, command, requested trials, elapsed time,
exit status and each process's raw log. A passing exit without exactly one
passing registered property is rejected. Failure or interruption preserves a
FAIL report and the active batch's diagnostic log. Completed batch logs remain
available. Tracked sources must stay unchanged throughout a campaign.

To reproduce, use the report's command and `HTTP_KIT_FUZZ_CASE` selection with
the matching sources/toolchain. A null selection means unset that environment
variable. Keep the original report and input when minimizing a failure; add a
small deterministic regression before fixing the implementation.

These are seeded generator trials, not coverage-guided search. Length guards in
some properties can skip expensive checks; trial counts are not assertions or
unique paths exercised. The existing scenario harness provides shrinking for its
own scenario format; this runner does not automatically shrink Crowbar failures.
Byte-input capture/minimization, richer state generators, long release durations
and independent review remain open. A PASS here does not certify release readiness,
bounded RSS, or the skipped AFL campaign. CI integration is deferred by request.
