# Native generated-input campaigns

Run the existing Crowbar properties without AFL or instrumentation:

```sh
tools/dev native-fuzz --rounds 10000 --batches 3 --seed 42
tools/dev native-fuzz --target websocket --rounds 100000 --batches 10 --seed 100
tools/dev native-fuzz --target request --input path/to/failure.input
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

When a generated-input property throws, the harness also saves its exact input
bytes in a private, exclusively created `.input` file. It never overwrites an
existing capture, and a capture error cannot replace the original property
exception. The failed run records the capture path and hash when available.
Process termination, timeout, generator failure before the property is called,
or an unwritable capture directory can leave no captured input; keep the seed,
command and log as well. These properties skip oversized inputs by returning;
they do not use Crowbar's discard exception inside the captured callback.

`--input` replays one selected target directly on those bytes, without generation.
It accepts a regular file of at most 64 KiB and snapshots it into the report
directory. It cannot be combined with `--rounds`, `--batches` or `--seed`.
The report identifies raw replay separately from seeded trials. Length guards
still apply, so a passing oversized-for-that-property input may have skipped its
expensive checks. Crowbar's positional `FILE` argument is generator entropy;
it is **not** a substitute for raw-byte replay.

To reproduce, use the report's command and `HTTP_KIT_FUZZ_CASE` selection with
the matching sources/toolchain. A null selection means unset that environment
variable. Keep the original report and input when minimizing a failure; add a
small deterministic regression before fixing the implementation.

These are seeded generator trials, not coverage-guided search. Length guards in
some properties can skip expensive checks; trial counts are not assertions or
unique paths exercised. The existing scenario harness provides shrinking for its
own scenario format; this runner does not automatically shrink Crowbar failures.
Use the separate minimizer below for captured bytes. Richer state generators,
long release durations and independent review remain open. A PASS here does not certify release readiness,
bounded RSS, or the skipped AFL campaign. CI integration is deferred by request.

## Minimize a captured property failure

```sh
tools/dev native-minimize --target request --input path/to/failure.input \
  --attempts 1000 --seconds 300 --timeout 5
```

This native OCaml tool deletes contiguous ranges while preserving the original
property exception class and exact backtrace. It reproduces the original twice
and requires two matching replays before accepting each smaller input. A different
failure site cannot replace the original finding. Missing failure identity,
unexpected process exits, timeouts and inconsistent replays abort with a FAIL
report; they never count as a successful reduction. This tool minimizes property
exceptions, not process crashes or hangs.

Each run retains `original.input`, `best.input`, every probe input/log and a report
under `_artifacts/native-minimize/run-*/`. The report records source/binary/input
hashes, failure identity hash, budgets and probe outcomes. Keep tracked sources and
the binary unchanged during minimization. Inputs are limited to 64 KiB, attempts
to 10,000, total requested time to one day, and each replay to one hour. Defaults
are 1,000 attempts, 300 seconds overall and 5 seconds per replay. Process cleanup
can add time after a timeout; there is no total RSS or log-size guarantee.

A completed PASS establishes that no single byte deletion preserves that failure
under this replay oracle. It does not establish the globally smallest input or
explain the defect. Exhausting the attempt/time budget between probes retains the
best twice-reproduced input as `BUDGET_EXHAUSTED`, with minimality explicitly false.
Timing out inside a replay is inconclusive and produces FAIL. The command prints
the outcome and report path; callers must inspect the report rather than treating
a zero exit alone as completed minimization. Add the reduced input as a permanent
regression test and keep the original evidence before fixing the defect.
