# Implemented M0–M1 harness contract

This is an executable scaffold for testing future HTTP primitives. Its current subject is intentionally a synthetic stream machine. `Begin` announces a message and a byte count directly; no code parses an HTTP header. The client/server role is recorded for future bindings but does not claim different protocol behavior yet.

M2 adds a separate real subject: the public `httpkit-core` library. `tools/harness run --suite core` executes its constructor/security/property tests; the default `all` suite runs both subjects and labels its scope. Core does not pretend to implement the synthetic stream machine. The [package design](design.md) documents its actual limits. The installed-consumer checks and microbenchmarks are external validation steps recorded by `tools/devlib/evidence.ml`, and `readiness --milestone M2` requires their source-matched evidence. Protocol and runtime capabilities remain pending.

## Independent implementations

`Model` is an immutable oracle with string state. `Fake_subject` uses mutable queues and separate transition code. Neither calls the other's transition logic. `Runner` checks observations and resource snapshots after each action and stops at the first divergence. Future real subjects must bind public APIs without repairing behavior inside the test binding.

Messages progress through waiting for synthetic headers, body, completed, and closed. `Input` accepts a bounded prefix; `Consume` releases bytes; `Send` accepts an entire tokenized command or returns backpressure; `Write` acknowledges a permitted prefix. `Finish` requires consumed input and drained output. `Wait_body`, cancellation, EOF, injected I/O errors, virtual time, and bounded runnable-work actions exercise lifecycle behavior.

Header staging is cleared by `Begin`; this is a synthetic test convention, not an HTTP parsing policy. Shutdown is deliberately a small model that returns backpressure until queues drain, then closes. Real graceful shutdown, handoff, headers, trailers, framing and runtime-specific behavior remain unimplemented.

## Scenario format

JSON schema version 1 uses exact keys. IDs/configuration/counts/time values use unsigned decimal strings; bytes use canonical base64. A materialized script records its role, seed label, configuration, and actions. It does not require regeneration from a PRNG seed.

The loader rejects unknown/duplicate fields, invalid base64, unsafe IDs, depth above 32, encoded input above 8 MiB, decoded data above 1 MiB, more than 4,096 actions, connection IDs outside 0–7, invalid capacities, native integer overflow, and virtual-time/deadline overflow. It validates open/begin prerequisites without removing intentional lifecycle misuse cases.

Defaults for this small harness are 8-byte incoming/outgoing capacities, a 10-nanosecond virtual header deadline, and a 10,000-operation budget. They are small test values, not proposed production timeouts.

Expected parser errors are not swallowed exceptions. Unknown subject exceptions are failures. The explicit operation budget detects excess returned work; the separate parent-process watchdog detects a call that never returns. The watchdog is exercised with both a hanging and a signaled child. AFL supplies an external per-input watchdog during fuzzing.

## Fault detectors and normalization

Planted variants cover dropped/duplicated writes, overconsumed input, empty-input/EOF confusion, repeated acceptance after backpressure, duplicate completion, data after completion, reuse of unread data, excess buffering, a missed cancellation wakeup, sliding deadlines, and unproductive runnable work.

Normalization merges only adjacent body-data events with the same connection and message identity. It retains completion and message boundaries. Tests demonstrate that different messages cannot collapse into one accepted transcript.

Shrink attempts delete action chunks and simplify bytes/counts/time while preserving scenario prerequisites and the original failure rule. The CLI enforces a 60-second deadline plus a 1,000-attempt budget. It records exhausted budgets and writes the reduced script to a separate file. More advanced semantic/message shrinking will grow with actual protocol subjects.

## Evidence boundaries

Tool ownership is mise → opam → Dune: mise pins opam, an isolated opam switch owns the pinned Dune executable, and Dune locks own the project compilers and dependencies. `mise.toml` is included in the evidence fingerprint.

The current registry labels implemented entries `IMPLEMENTED_SELF_TEST`; all 15 production capability groups remain pending. Dune package management builds the compiler and dependencies from `dune.lock/` (OCaml 5.5.0 only). Compiler evidence records the selected lock, package versions, actual running compiler, and source hashes including both workspace and lock directories. The M0 gate rejects missing or stale evidence. Raw AFL maps, logs, a discovered fault input, and replay output are retained under `_artifacts/afl/`.

CI schedules beyond PR checks, coverage measurement, HTTP/proxy conformance, API consumer projects, runtime adapter tests, and performance benchmarks are not implemented in this slice. The long-term plan remains the specification for those milestones; placeholder suites do not return success.
