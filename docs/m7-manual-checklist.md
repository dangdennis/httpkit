# M7 manual completion checklist

M7 is the release-evidence milestone, not another implementation package. It is
complete only when every required gate passes for one frozen candidate. The five
packages exist; CI smoke success alone does not establish release readiness.

## Ownership and candidate isolation

You own long campaigns, the retained timeout investigation, independent reviews,
the license, and verification of the private reporting channel. The coding agent
is finishing CLI/CI integration and may subsequently change implementation code.
Do not run a release campaign in that changing checkout.

First choose and commit the license and finish any required harness code. Then
select the candidate commit and create a separate checkout (commands from the
repository root):

```sh
git rev-parse HEAD
git worktree add --detach ../http-kit-m7-review HEAD
cd ../http-kit-m7-review
mise trust
mise install opam
mise run setup
mise run setup:afl
mise run setup:nginx
python3 tools/evidence.py fingerprint
```

Record the full commit and fingerprint with your results. Use the same commit on
Linux x86-64 and macOS arm64, both with OCaml 5.5.0. Build caches and `_artifacts`
are local to each checkout and are not transferred by creating a worktree.
Save evidence outside the checkout as well. Do not edit sources, locks, docs, or
license while collecting final evidence; those files contribute to the hash.
If a finding requires a fix, commit it and collect evidence for the new candidate.
Evidence for an older commit remains useful history, not approval for the fix.

## 1. Baseline and development evidence

Run these sequentially; several tools share the normal build directory:

```sh
python3 tools/evidence.py validate 5.5.0
python3 tools/fuzz-smoke.py
python3 tools/interop.py
python3 tools/performance.py
python3 tools/coverage.py
python3 tools/mutations.py
python3 tools/test_release.py
```

Required results: tests/docs/installed consumers pass, AFL positive controls pass,
six direct/Nginx lanes pass, hard streaming limits hold, all three curated mutants
compile and fail their named tests, and core/codec/engine point coverage is at least
95% with no missing executable files. Inspect adapter coverage and uncovered
branches separately; the aggregate percentage is not a security guarantee.
The performance script's timing is advisory, not the stable-performance gate.

Latest checks before the CLI/CI integration passed on 5.5.0 with 96.32% measured
core/codec/engine point coverage. Recompute after the candidate is frozen.

## 2. Retained request timeout — still open

The existing local checkout contains the original input at:

```text
_artifacts/campaigns/b21cef3765e7-39l8_dqp/request/default/hangs/id:000000,src:000063,time:30037,execs:121112,op:havoc,rep:1
```

Its SHA-256 is
`d8e43ca80ca7b49d20b83727a978efbf1b10eaabed29e0aeb2c2ff9ceabd3a3b`.
Copy that retained campaign directory into your evidence archive before moving
machines. It is ignored by Git and therefore is not in the pushed repository.
Six later local replays passed (three normal and three instrumented), recorded in
`_artifacts/request-timeout-replays.json`. This does not establish a root cause.

Reproduce on the frozen candidate using the request selector, both normal and
instrumented binaries, and the original AFL memory/time limits. Preserve versions,
commands, timings, logs, and the input. Determine whether the cause is parser
behavior, runner shutdown, scheduling, or another infrastructure issue. If it is
a code defect, add a deterministic regression and fix it. If it is infrastructure,
record evidence for that classification and verify the corrected runner. Do not
delete the finding or simply raise the timeout to obtain a green result.

## 3. Smoke, then full campaigns

```sh
python3 tools/campaign.py --seconds 30
python3 tools/campaign.py --seconds 28800
```

The second command runs eight hours **per target**, up to 72 hours of fuzz CPU for
all nine targets. Retain complete logs/corpora and the resulting `campaign-*.json`.
Completion requires no untriaged crashes/hangs and successful uninstrumented
replay of the retained corpus. A failed command means the campaign is incomplete.

To run one target independently, use `--target NAME`: `core`, `request`, `response`,
`chunked`, `server`, `client`, `partial-write`, `isolation`, or `adapter`.
Do not run concurrent invocations in one checkout: they share builds and report
names. Separate machines/checkouts can collect different targets at the exact same
source hash; merge only the matching reports and preserve their backing artifacts.

## 4. Additional evidence that is not implemented by the smoke scripts

These require real experiments or additional harness implementation. There is no
one-command completion shortcut in the current repository.

| Gate | Required work |
| --- | --- |
| `reference-differential` | Implement/run the planned pinned Hyper/httpun comparison and broader HAProxy/Nginx matrix. Classify differences against protocol contracts; majority agreement is not the oracle. |
| `proxy-observers` | Correlate raw sender, backend wire, and application invocation records. Account for forwarded, consumed, dispatched, and answered messages. Proxy rejection alone does not prove engine rejection. |
| `stable-performance` | Establish a stable baseline runner; collect three repeatability sessions and five alternating baseline/candidate pairs. Follow the offered-load, confidence interval, and regression rules in the harness plan. Existing same-source advisory runs do not qualify. |
| `soak` | Run at least two hours of sustained mixed load per adapter, including cleanup/cancellation and resource observations. Require correct output, bounded backlog/resources, and reviewed failures. The current short performance runner is not a soak runner. |
| `contract-coverage` | Map every applicable required contract and lifecycle transition to positive, negative, and boundary evidence, plus exclusions with justification. Review gaps; do not equate point coverage with contract coverage. |

See sections 14–18 of [the detailed harness plan](test-harness-plan.md) for exact
protocol, performance, API, and coverage criteria. If a requirement is intentionally
removed, that is a reviewed change to scope/policy before a new candidate freeze,
not a passing artifact for work that was never performed.

## 5. CI, independent reviews, and owner decisions

- Confirm the candidate's GitHub workflow succeeds on both declared platforms.
  Download the run artifacts with `gh run download RUN_ID --dir /path/to/archive`.
  Check compiler values, source hashes, required job conclusions, and report
  contents. Preserve the run URL, full commit, job/platform mapping, and artifacts.
- Obtain an independent security review of framing, ownership, limits, cancellation,
  oracle independence, and the coverage gaps. Resolve findings and rerun affected
  evidence after fixes. An implementation agent cannot supply independent approval.
- Arrange an API review using installed packages and docs: build an in-memory
  exchange, stream a response, and handle cancellation. Record confusing errors,
  conversions, undocumented steps, and ownership obligations. Resolve defects.
- Choose and commit a license before the final freeze. No license was selected by
  the coding agent.
- Verify a working private vulnerability-reporting channel before publication,
  and record who verified it. Follow [SECURITY.md](../SECURITY.md). Committing or
  pushing does not publish packages or change repository visibility.

## 6. Record reviewed evidence and assess

Generated reports are written under `_artifacts`. Review/extended/platform reports
currently require manual assembly from real results. Every report must have
`status: "PASS"` and `source_sha256` equal to the candidate fingerprint, plus:

| File | Required additional fields |
| --- | --- |
| `platform-matrix.json` | `passed`: includes `linux-x86_64/5.5.0` and `macos-arm64/5.5.0`; retain supporting CI run/job URLs and archived reports. |
| `security-review.json` | `reviewer`, `review_url`, `approved: true`, `independent_of_implementation: true`, `unresolved_findings: []`. |
| `api-review.json` | `reviewer`, `review_url`, `approved: true`, `unresolved_findings: []`. |
| Each gate in section 4, named `GATE.json` | Nonempty `evidence_paths`, `approved_by`, and `unresolved_findings: []`; point to the real reviewed experimental records. |
| `private-reporting.json` | `verified_channel`, `verified_by`; include the verification date and outcome as supporting evidence. |

Only write approval fields after the named person has actually reviewed and
approved the evidence. The machine checks fields and freshness; it does not
verify reviewer identity or the truth of manually supplied results. The maintainer
must verify supporting material. Missing work remains `NOT_READY`.

```sh
python3 tools/release.py --output _artifacts/release.json
tools/harness readiness --release
tools/harness readiness --milestone M7
```

Exit 3 / `NOT_READY` lists remaining gates. Exit 0 / `READY` means the machine's
checks passed; the verified reviews and supporting records must also be complete.
Archive the entire release evidence bundle, candidate commit, and fingerprint.
