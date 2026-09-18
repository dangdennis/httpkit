# Security policy

httpkit is pre-release. Passing a milestone or a fuzz smoke run is not approval for an internet-facing release. `tools/dev release` lists the remaining evidence gates.

The owner-approved next milestone is a GitHub beta under MIT, with WebSockets
experimental. `tools/dev release --profile beta` assesses local engineering and
staging evidence; production remains the default profile and additionally requires
independent security/API review. A beta pass is not a production recommendation.
Public publication requires the owner's final review of the prepared release.

## Reporting privately

This repository is public. GitHub private vulnerability reporting is enabled
(verified 2026-09-15). Use [Report a vulnerability](https://github.com/dangdennis/httpkit/security/advisories/new)
to report privately to the maintainers. Do not put exploit details, reproducing
inputs or credentials in a public issue.

Reporting requires a GitHub account. The channel's enabled state has been verified;
no test vulnerability report was submitted. This policy does not promise a response
SLA. Recheck channel availability when preparing a release.

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

See [validation status](docs/status.md), [release requirements](docs/release.md)
and [deployment contracts](docs/deployment.md). Dependency changes must refresh
locks and rerun affected evidence. Policy v2 replaces AFL with native campaigns
and unavailable hosted CI with reproducible local Linux/macOS evidence. Neither
skipped activity is reported as passed. Stale source hashes remain invalid, and
absent independent review stays visible as pending for beta and blocking for
production.
