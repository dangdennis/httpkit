# Synthetic scenario harness

This harness checks a synthetic stream machine against an independent model.
`Begin` announces a message and byte count directly; it does not parse HTTP.
Its small capacities and virtual deadlines are test fixtures, not server defaults.

Real core, codec, engine and runtime tests run separately through the public APIs.
See [testing](testing.md) for those checks and [release policy](release.md) for
acceptance. Passing the synthetic model does not establish protocol correctness.

## Independent implementations

`Model` is an immutable oracle with string state. `Fake_subject` uses mutable queues and separate transition code. Neither calls the other's transition logic. `Runner` checks observations and resource snapshots after each action and stops at the first divergence. Real subjects must bind public APIs without repairing behavior inside the test binding.

Messages progress through waiting for synthetic headers, body, completed, and closed. `Input` accepts a bounded prefix; `Consume` releases bytes; `Send` accepts an entire tokenized command or returns backpressure; `Write` acknowledges a permitted prefix. `Finish` requires consumed input and drained output. `Wait_body`, cancellation, EOF, injected I/O errors, virtual time, and bounded runnable-work actions exercise lifecycle behavior.

Header staging is cleared by `Begin`; this is a synthetic test convention, not an HTTP parsing policy. Shutdown is deliberately a small model that returns backpressure until queues drain, then closes. Actual HTTP framing, handoff and runtime cleanup are tested by the separate protocol and adapter suites.

## Scenario format

JSON schema version 1 uses exact keys. IDs/configuration/counts/time values use unsigned decimal strings; bytes use canonical base64. A materialized script records its role, seed label, configuration, and actions. It does not require regeneration from a PRNG seed.

The loader rejects unknown/duplicate fields, invalid base64, unsafe IDs, depth above 32, encoded input above 8 MiB, decoded data above 1 MiB, more than 4,096 actions, connection IDs outside 0–7, invalid capacities, native integer overflow, and virtual-time/deadline overflow. It validates open/begin prerequisites without removing intentional lifecycle misuse cases.

Defaults for this small harness are 8-byte incoming/outgoing capacities, a 10-nanosecond virtual header deadline, and a 10,000-operation budget. They are small test values, not proposed production timeouts.

Expected parser errors are not swallowed exceptions. Unknown subject exceptions are failures. The explicit operation budget detects excess returned work; the separate parent-process watchdog detects a call that never returns. The watchdog is exercised with both a hanging and a signaled child. AFL supplies an external per-input watchdog during fuzzing.

## Fault detectors and normalization

Planted variants cover dropped/duplicated writes, overconsumed input, empty-input/EOF confusion, repeated acceptance after backpressure, duplicate completion, data after completion, reuse of unread data, excess buffering, a missed cancellation wakeup, sliding deadlines, and unproductive runnable work.

Normalization merges only adjacent body-data events with the same connection and message identity. It retains completion and message boundaries. Tests demonstrate that different messages cannot collapse into one accepted transcript.

Shrink attempts delete action chunks and simplify bytes/counts/time while preserving scenario prerequisites and the original failure rule. The CLI enforces a 60-second deadline plus a 1,000-attempt budget. It records exhausted budgets and writes the reduced script to a separate file. Captured property bytes use the separate [native minimizer](native-fuzz.md#minimize-a-captured-property-failure).

## Evidence boundaries

The registry distinguishes `IMPLEMENTED_SELF_TEST` entries from real-subject
requirements; `release-evidence` remains pending. `tools/harness registry` prints
the current inventory. Compiler reports bind the toolchain, workspaces, locks and
source hashes to results. Missing or stale required evidence cannot pass readiness.
See [development](development.md) for toolchain setup and replay commands.
