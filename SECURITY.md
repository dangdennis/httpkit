# Security policy

httpkit is pre-release. Passing a milestone or a fuzz smoke run is not approval for an internet-facing release. `tools/dev release` lists the remaining evidence gates.

## Reporting privately

This repository is currently private. Collaborators can report a suspected vulnerability in a private repository issue, addressed to the repository owner, `@dangdennis`. Keep exploit details and reproducing inputs inside the private repository. Access to that issue follows repository access permissions; it is not a separate security team inbox.

Before making the repository or a release public, the owner must configure and verify GitHub private vulnerability reporting or provide another private contact. That verification is an explicit release gate. The current repository does not provide a verified public reporter channel, and this document does not invent an email address or promise a response SLA.

Include the affected revision, package/runtime/compiler, a minimal request or schedule, expected versus actual behavior, relevant limits, and whether the issue affects framing, ownership, cancellation, confidentiality, or availability. Use synthetic data and remove credentials and personal information. Raw request bodies should be attached as files when text formatting would alter bytes.

## Maintainer process

1. Reproduce in an isolated local test process. Record the original input and its hash, exact dependency locks, and the affected capability. Preserve crash/hang inputs before shrinking.
2. Determine affected versions and whether the defect is in the primitives, adapter, application policy, or an external dependency. Review similar parser and lifecycle paths, including the other runtime adapter.
3. Add a deterministic regression, fix the implementation, and verify that an intentional reintroduction of the defect is detected when practical.
4. Run the affected compiler/platform, install/API, interop, resource, and fuzz gates. Rerun the full affected release campaign after a fix; an engine-wide change invalidates engine-dependent campaigns.
5. Arrange independent review of the patch and prepare a coordinated advisory and patched release. Keep the issue private while an effective fix is being prepared. The owner decides publication and any advisory/CVE coordination.

## Supported claims and experimental features

All packages are pre-release; none has completed the production-confidence gates.
Strict HTTP/1.1 parsing/encoding and engine ownership are the primary security
review target, supported by executable controls rather than independent approval.
Application routing, middleware, cookies/sessions, uploads, DB and OIDC/password
wrappers are implemented, but their feature-specific release evidence remains
incomplete. Presence of a wrapper does not certify upstream dependencies.

**WebSockets are experimental.** Framing, message reassembly and realtime helpers
exist; do not treat them as production-security supported until masking, UTF-8,
fragmentation, limits, concurrent sends, upgrade and cancellation campaigns pass
and independent review is recorded. Multipart/uploads also require their own
confinement, disk-failure and cancellation acceptance.

Railway normally terminates public TLS; Caddy is optional. Edge deployment never
waives backend HTTP/1 framing, proxy-trust or resource limits. Forwarding metadata
is untrusted unless the immediate peer is explicitly trusted. No WAF/DDoS service
or public certificate manager is part of httpkit.

See [production roadmap](docs/protocol-libraries-plan.md), [audit](docs/production-audit.md)
and [deployment contracts](docs/deployment.md). Dependency changes must refresh
locks and rerun affected evidence. Skipped AFL, missing hosted CI, stale source
hashes or absent independent review must not be represented as passing gates.
