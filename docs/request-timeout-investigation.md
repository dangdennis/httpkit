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
precede the final candidate freeze; use the reproducible command for current data:

```sh
python3 tools/triage_timeout.py
```

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
