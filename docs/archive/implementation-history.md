# Implementation history

Condensed from the September 2026 implementation plans. These records explain
completed work; they are not a current backlog or release approval. See
[current status](../status.md), [testing](../testing.md), and [release policy](../release.md).
The detailed original checklists remain in Git history at `49246bd`.

## Code-quality consolidation

The C1–C12 implementation record reported these changes complete:

| Slice | Result |
| --- | --- |
| C1 | Non-removable operational checks and explicit release inventories |
| C2–C3 | Expect gating includes final framing; native examples decide before reading uploads |
| C4 | Balanced-set trailer membership replaces repeated list scans |
| C5 | Adapter tests distinguish failure categories and verify cleanup precedence |
| C6 | Retained benchmark aggregates and exclusions are recomputed from raw samples |
| C7 | Pipeline requests/responses carry ordinal identities; reorder and omission controls fail |
| C8–C9 | Named benchmark configurations, selected-only preparation, calibrated execution budgets |
| C10 | Separate private receive/send states and explicit lifecycle transitions |
| C11 | Adapter configuration/diagnostics and typed Transition examples in both runtimes |
| C12 | Grouped test catalogs, ownership docs and source-matched validation |

The optional single-character chunk predicate optimization was deferred pending
measurement. Benchmark-only router indexes did not replace production routing.
Eio and Lwt retain separate native cancellation machinery.

## Application layer

The framework plan's F1–F9 stages delivered bounded URL/forms/JSON/HTML helpers,
Eio dispatch and middleware, sessions/CSRF, multipart uploads, confined static
files, SSE/experimental WebSockets, Caqti database integration, and composed
examples. Lwt applications and optional authentication/session packages followed.

Usage and ownership now live in [framework](../framework.md),
[extensions](../extensions.md), [lifecycle](../lifecycle.md), and
[limits](../production-limits.md). Completing implementation did not complete
soak, deployment or independent-review gates.

## Production-confidence work

The September 14 roadmap prioritized protocol, lifecycle and resource evidence
rather than package expansion. It led to:

- Authored framing/chunk/EOF matrices and segmentation/reuse controls.
- Joined cancellation cleanup for handlers, uploads, database leases and late accepts.
- Shared fail-closed proxy policy and application timeout configuration.
- Native generated-input capture, replay, minimization and duration campaigns.
- Endpoint, capacity, slow-client, blocked-output and unread-body measurements.
- Privacy-preserving observations and explicit enqueue-versus-delivery semantics.
- Feature/dependency review and installed-package isolation checks.

The [original audit](production-audit.md) and [feature review](beta-feature-review.md)
retain specific findings. Current outcomes and unresolved issues belong in
[status](../status.md); commands and budgets belong in [release](../release.md).

## Earlier personal-use profile

The historical Eio profile used 1,800 seconds per catalog fuzz target and a
7,200-second mixed-load soak. Its workload budgets were 256 MiB RSS, 32 MiB warmed
RSS growth, 1 MiB equivalent-idle live-heap variation and two descriptors of
variation. These are workload-specific limits, not universal production bounds.
The executable recipe remains in [Eio streaming examples](../personal-eio.md).
AFL and its retained timeout investigations remain deferred; the
[original findings](../request-timeout-investigation.md) are not resolved by later passes.

## Scope decisions retained

Strict HTTP/1.1 remains the protocol target. Reuse upstream cryptography and keep
core, codec, engine, native transports and optional extensions separate. Public
TLS termination, certificate management, reverse proxies, CDN/WAF services and
HTTP/2/3 infrastructure are outside the library scope. New features require a
concrete application need. Client API review remains deferred.
