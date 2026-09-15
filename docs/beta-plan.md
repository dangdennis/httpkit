# Approved public beta delivery plan

Approved 2026-09-14. Target: GitHub prerelease `v0.1.0-beta.1`, package version
`0.1.0~beta1`, MIT, pin-install instructions, no central opam submission yet.
All existing HTTP/application/auth/session/database/upload features are in the
beta acceptance scope. WebSockets stay available and experimental. Production
claims require a later independent security/API review.

## Execution and checkpoints

Preserve changes; work on main in small tested commits, pushing each completed
slice. Keep README concise. No Python, custom crypto, AFL or hosted CI work.
GitHub Actions quota is exhausted; do not wait for it or treat unavailability as
failure/success. Lwt correctness remains required; benchmark parity is deferred.

Defaults selected in the planning conversation: 64 concurrent connections, a
512 MiB app-memory budget, resumable validation sessions capped at 12 hours.
Existing constructor defaults remain unchanged; this is an opt-in tested profile.
Fix measured pathological behavior and capacity failures before broader tuning.

Two owner checkpoints remain: approve an exact hosted staging resource/cost plan
before creating paid resources; approve the prepared public release before
changing repository visibility or publishing. No external-review approval is
invented. Existing main commit/push authorization remains in effect.

## Ordered slices and exit conditions

| Slice | Work | Exit condition / status |
| --- | --- | --- |
| 1 | Beta/production gates, policy and evidence manifests | Profile separation and rejection controls implemented; actual candidate campaign evidence remains pending |
| 2 | Multipart controls and WebSocket allocation investigation | Multipart controls fixed; incremental/coalesced WebSocket quadratic copying reproduced and replaced with buffered parsing; segmented protocol and allocation regressions pass |
| 3 | Feature security, lifecycle and ownership review | [Feature/ownership matrix](beta-feature-review.md), static controls and bounded password-worker example implemented; historical causes and remaining fault campaigns stay open |
| 4 | Queue/rejection/admission/shutdown diagnostics and API contracts | Queue occupancy, body rejection, saturation and shutdown progress implemented with both-runtime controls; remaining API/installation review pending |
| 5 | Checked/skipped native fuzz accounting, resumable campaigns, coverage/mutations | Accounting, length-boundary generators and identity-checked resumable runner implemented; actual14-target30min/100000-checked/20-seed campaigns and fresh95/85/80% coverage remain pending |
| 6 | Capacity, slow-client/overload stress, allocation profiles | Opt-in64-connection endpoint profile,1/16/64-slot admission/backlog, incomplete-input and observed blocked-output runners implemented; unread bodies, sustained bounded-capacity proof, stable profiles, SQLite30min/PostgreSQL2h and idle/slow/overload30min campaigns pending |
| 7 | Reproducible local platforms and approved hosted staging | [Local Linux/macOS recipe](local-validation.md) implemented; Linux x86_64/posix validation and actual direct-edge contract/lifecycle evidence remain acceptance work; hosted campaign requires cost approval |
| 8 | MIT/notices, dependency inventory, private reporting, archive/pin installs and release notes | Exact beta candidate passes gates and is prepared for owner publication review |

For every substantial change: identify invariant/test, implement smallest fix,
run narrow then relevant regression suites, inspect security/performance effects,
update semantics documentation and commit. Reintroduce confirmed defects only in
temporary validation copies to prove the regression detects them.

## Detailed acceptance boundaries

Multipart covers illegal controls, legal SP/HTAB, boundary prefixes, quotas,
segmentation, terminal errors and callback cleanup. WebSocket measurements cover
complete/incremental/fragmented frames, coalesced input and allocation scaling;
experimental status does not excuse a confirmed resource defect.

Feature review includes confined static/nonregular/symlink paths; upload
write/close/unlink and cancellation; cookie replay/rotation/CSRF/expiry; SQL
rotation/revocation; OIDC claims/browser binding/remote limits; bounded synchronous
password-work admission; lease escape, rollback and pool shutdown; parsing,
handler and streaming cancellation and connection reuse. Preserve historical
replay artifacts and distinguish generator entropy from raw HTTP bytes. Passing
an unrelated or wrong-format replay does not resolve a finding.

Diagnostics add queue occupancy, body-limit rejection, admission saturation and
shutdown progress without inventing rejection when work waits outside the app.
No vendor dependency or unbounded event queue. Preserve response-enqueue versus
transport-progress and peer-receipt semantics. Change APIs only for evidenced
misuse/ownership problems; keep existing package/runtime boundaries.

Capacity workloads use1/16/64 concurrent connections and128 attempted connections
for overload, with slow headers, stalled bodies, slow readers, idle keep-alive,
unread bodies, disconnected uploads/streams and shutdown during cleanup. Require
RSS<512MiB, post-warmup RSS median growth<=32MiB, equivalent-idle post-GC live-heap
variation<=1MiB, idle descriptor return within2 of baseline, zero unexpected
errors, complete admitted-connection closure and effective deadlines. Preserve
existing lower-concurrency resource tests. Record scheduling tolerance explicitly.

Profile the five existing endpoints at1/4/8/16/64 concurrency using five30s samples
per configuration, release build, recording throughput/latency/CPU/GC/allocation
and RSS. Keep timing advisory until a repeatable controlled comparison exists.
Do not confuse cumulative allocation with retained memory or load-client changes
with server improvements. Optimize only measured problems or capacity failures.

Staging proposal: separate Eio app and PostgreSQL, synthetic data and capped
separate load generator, exact duration/resource/cost/teardown plan. Real direct
Railway acceptance follows budget approval; optional Caddy remains local and
Cloudflare chains unverified. Keep forwarded identity disabled unless peer
isolation and normalization are demonstrated; configured canonical origins are
an acceptable profile. Capture exact image/deployment identities, run bounded
canary plus2h mixed workload, export evidence and perform approved teardown.

The publication checklist includes a verified private reporting channel, actual
production native/transitive dependencies and licenses, exact archive installs,
public-history/material review, and no credentials/private artifacts in the
public evidence summary. Do not rewrite history automatically on a finding.

## Evidence freeze and later production claim

Finish tracked source/docs/locks before final campaigns. Resume only with matching
source/binary/toolchain/policy identities; source changes invalidate release
acceptance. Keep failures/timeouts as failures and old reports as history.
[Release policy](release.md) defines profile results and manifest fields. Evidence
collection is separate from pretending required work has happened.

After beta, resolve real independent security/API findings before a production
recommendation. Broader optimization, full WebSocket certification, larger
capacity, hosted multi-proxy acceptance and Lwt benchmark parity are separate
follow-ups. HTTP/2/3, public TLS management, reverse proxying and new feature
libraries remain excluded.
