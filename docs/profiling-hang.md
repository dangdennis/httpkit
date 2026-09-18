# Profiling hang investigation

Updated 2026-09-18. **Unresolved.** Diagnostic tools are in `d39f021`.

## Reproduction and evidence

The long profile runs five workloads at 1/4/8/16/64 connections, five 30-second
samples per configuration. Three attempts stopped after 122 completed epochs,
in the third large-stream sample at 64 connections. Other complete runs passed.
A passing retry does not explain the failure.

The instrumented attempt captured:

- 56 workers waiting to reacquire the runtime lock after socket read/select;
- eight workers that finished, with the client sampler still running;
- a server that answered `/health`, with no unexpected application errors recorded;
- an external watchdog timeout and cleanup, preserving the stalled report.

A standalone test using 64 threads, nonblocking socket pairs and 8 KiB copies
also stalled after roughly 20 million completed iterations. It uses OCaml's Unix
and threads libraries, with no httpkit or HTTP code. Stacks again show runtime-lock
waits. A bounded debugger attach did not complete, so lock-object state is missing.

## Controls

| Control | Result |
| --- | --- |
| Short framework and independent-server streams at 16/64 connections | Passed |
| 38.4 million explicit thread yields | Passed |
| 38.4 million zero-time select calls | Passed |
| 128 thread generations, 33.55 million select calls | Passed |
| 38.4 million reads and 8 KiB allocations from `/dev/zero` | Passed |
| Raw socket pairs plus allocation | Stalled; watchdog timed out |

The first three standalone scheduling controls used the existing opam OCaml 5.5.0
build. Its systhreads sources match the repository compiler, but its binary differs.
The read/allocation and raw-socket controls used the exact repository compiler.
None is a production performance benchmark.

## Capture a profile

```sh
tools/dev endpoint-profile --diagnostics --profile release \
  --concurrencies 1,4,8,16,64 --seconds 30 --repetitions 5
```

`workers.json` records worker phases and operation counts. `processes.json`
identifies the owned client/server/port; `report.json` marks `diagnostic_run: true`.
Use an external watchdog for stack capture and cleanup: an in-process sampler
cannot guarantee progress when its runtime stalls. Diagnostic timings do not
qualify as ordinary throughput acceptance.

Next: reduce the standalone socket reproducer and inspect runtime/OS lock state
or compare the same reproducer on the target platform. Do not weaken deadlines,
suppress errors, change compiler pins speculatively, or label a successful retry
a fix. Raw captures and standalone drivers are retained in local
`_artifacts/acceptance63` and `_artifacts/acceptance64`.
