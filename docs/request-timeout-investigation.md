# Retained request timeout investigation

Status: unresolved historical finding; successful replays are not a root cause.

The original AFL 4.31c run recorded one timeout after 121,166 executions, at
30,037 ms near the end of its 30-second campaign. Its configured execution timeout
was 2,000 ms and memory limit 512 MiB. No crash was recorded. The input SHA-256 is
`d8e43ca80ca7b49d20b83727a978efbf1b10eaabed29e0aeb2c2ff9ceabd3a3b`.
It is now preserved in `fuzz/corpus/request/retained-timeout.seed` and included in
subsequent request campaigns. The original campaign remains under `_artifacts`.

During the personal-use investigation, 100 ordinary and 100 instrumented direct
replays passed (maximum observed direct process duration approximately 16 ms).
Three fresh AFL runs with RNG seeds 42, 43 and 44, each lasting 30 seconds at the
original memory/execution limits, produced no findings. These initial observations
precede the final candidate freeze. The historical `tools/dev triage-timeout`
command also starts AFL and is excluded from the approved native-only beta plan.

The tool retains commands, logs, direct timing observations and AFL corpora in
`_artifacts/personal/timeout-*`. AFL needs shared-memory access. Its output keeps
`classification: UNRESOLVED` even when all replays pass. It does not alter timeouts,
delete historical findings or create a security approval.

The current evidence cannot distinguish a rare state-dependent defect from a
scheduling/forkserver interruption in the original run. End-of-run timing alone
is not evidence that shutdown caused it. The bounded request parser and successful
replays narrow the investigation but do not establish the historical cause.
A personal-use acceptance report must keep this finding visible. A clean long
campaign provides additional evidence, not an automatic resolution.

## AFL deferred

The user subsequently asked to skip all AFL work. The interrupted new core
campaign had recorded a 44-byte timeout input at 112,469 ms, after 585,549
executions. Its SHA-256 is
`18059b55b5a5736107d87ce9e676a20b9be0c21c5a0ae57c6a60d3137dd3b72e`.
The input is preserved as `fuzz/corpus/core/deferred-timeout.seed`; original logs
and corpus remain in `_artifacts/campaigns/a063c71df498-nb78ebzw`. It has not been
investigated or resolved. Non-AFL checks and the Eio soak continue separately.

## Input format boundary

Both retained `.seed` files are historical generator entropy, not captured HTTP
wire or lexical input. The old Crowbar byte generator reads up to64 decoded bytes,
stops at NUL and uses byte1 as an escape. The request seed contains an early NUL;
feeding the complete seed directly to the current request parser changes the
experiment. Selection bytes and generator revisions also matter. The native
generator now includes length-boundary cases, so its positional entropy replay
cannot establish equivalence to the original generator merely by reusing a file.

`native-fuzz --input` is appropriate for captured property bytes, not an automatic
substitute for these historical seeds. Preserve original source/binary/generator
identity before investigating decoded cases. Neither successful wrong-format
replay nor the new checked-input counters resolves the historical timeouts. Both
remain unresolved; no AFL campaign was run during this beta implementation.
