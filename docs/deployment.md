# Railway deployment and optional Caddy

The canonical production shape is Browser -> HTTPS Railway edge -> httpkit on
`$PORT`. No Caddy is required. Railway provides public certificates and renewal;
see [public networking](https://docs.railway.com/networking/public-networking).
This is a deployment contract/recipe, not a record of a completed deployment.

## Direct application

Build the executable and immutable assets into the image. After an appropriate
OCaml build stage, the runtime stage contains the equivalent of:

```dockerfile
WORKDIR /app
COPY --from=build /build/app.exe /app/httpkit-app
COPY public /app/public
CMD ["/app/httpkit-app"]
```

The fragment assumes the build produces `/build/app.exe`; select a compatible
runtime base and include required native libraries. The application must parse
and validate `PORT` at startup and bind an externally reachable container address,
not loopback. Railway documents `0.0.0.0:$PORT` for public reachability; private
networking may additionally require IPv6/dual-stack binding. Verify both paths for
the chosen runtime and environment. [Listener guidance](https://docs.railway.com/guides/vibe-coding-deploy),
[private networking](https://docs.railway.com/networking/private-networking/how-it-works).

Configure a public domain to the application port, bounded application admission,
request/body/output/deadline limits and a small readiness endpoint. SIGTERM should
stop admission and drain/cancel owned work within the graceful budget. The app can
serve `/app/public` with its existing confined static helper and finite file cap.
Do not disable backend framing/limits because an edge is present.

## Optional separate Caddy service

Browser -> HTTPS Railway edge -> Caddy service -> private httpkit service.
Use this only for needed compression, dedicated static delivery, multi-service
routing or proxy policy. Keep only the Caddy service public in this layout.
An illustrative Caddyfile for an explicitly set Caddy `PORT=8080` and a backend
listening privately on port 8080 is:

```caddyfile
:8080 {
    reverse_proxy http://httpkit.railway.internal:8080
}
```

Replace service name/port with actual values. Validate with the pinned Caddy
version before deployment. `encode` and asset routes are optional, application-
reviewed additions; avoid blanket compression of secret-bearing responses.
Railway private connections are protected by its Wireguard network and use the
service's actual port. [Private networking](https://docs.railway.com/networking/private-networking/how-it-works),
[Caddy reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).

Separate services have separate container filesystems. Caddy cannot read assets
baked only into the httpkit image. Either bake assets into Caddy's image too, serve
them through httpkit, or use object storage/CDN. Do not create a shared volume to
distribute immutable CSS/JS. Localhost is suitable only when processes share the
same container/network namespace; it does not address another Railway service.

## Immutable versus persistent files

| Files | Placement |
| --- | --- |
| Bundled CSS, JS, fonts, icons and images | Copy into the deployment image at build time |
| SQLite or small single-replica durable files | Explicit mounted persistent storage with backup/recovery policy |
| Important or horizontally scaled user uploads | Object storage such as S3/R2 with authorization and lifecycle policy |
| Partial uploads | Confined exclusive temporary files, removed on failure/cancellation |

Do not use Railway Volumes for immutable deploy assets. Volumes are mounted at
runtime, not build time; current documentation excludes replicas with volumes.
Do not assume an ephemeral container directory survives a redeploy.
[Volume lifecycle](https://docs.railway.com/volumes),
[volume constraints](https://docs.railway.com/volumes/reference).

## Forwarded metadata: fail closed

Default behavior is to ignore forwarding headers unless the immediate peer is
explicitly trusted. Public documentation of a header name does not authenticate
its contents. Do not infer trust from a private IP range or an existing header.

Both runtime `Common.proxy` helpers use the pure `Httpkit.Proxy.resolve` policy.
The default remains one X-Forwarded-For IP and one X-Forwarded-Proto value. For a
peer verified to normalize X-Real-IP, select it explicitly:

```ocaml
Httpkit_eio.Common.proxy ~ip_header:Httpkit.Proxy.Real_ip ~trusted_peer request
(* Httpkit_lwt.Common.proxy has the same synchronous policy API. *)
```

Duplicate selected fields, chains and RFC Forwarded are rejected. There is no
fallback between IP headers. The unselected IP field and X-Forwarded-Host never
supply client identity or application origin. Configure canonical origins
separately. The caller-supplied `trusted_peer` authenticates the immediate peer;
this example does not establish that trust or declare a topology verified.

Railway documents X-Real-IP, X-Forwarded-Proto and X-Forwarded-Host. Explicit
header selection addresses the parsing mismatch, while deployment isolation and
header sanitization still need observed acceptance evidence.
[Edge header contract](https://docs.railway.com/networking/public-networking/specs-and-limits).

| Topology | Required acceptance before enabling forwarded identity |
| --- | --- |
| Railway -> app | Verify immediate-peer isolation and observed sanitized header contract; explicit original-host allowlist |
| Railway -> Caddy -> app | Caddy trusts only its verified upstream; overwrites a canonical backend profile; app trusts only Caddy |
| Cloudflare -> Railway -> app | Verify both boundary sanitization steps; no assumed client-IP position |
| Cloudflare -> Railway -> Caddy -> app | Verify all hops and reject ambiguous/duplicate chains at the canonicalization boundary |

These profiles are not yet integration-verified. Keep metadata ignored until trust
can be established; use configured canonical application origins for redirects and
CSRF checks instead of guessing from headers. Exact trusted identities/CIDRs must
come from verified deployment facts. Caddy must not overwrite the original HTTPS
scheme with an untrusted input value or infer it merely from its plain backend hop.

Acceptance includes malicious duplicate/chain/Forwarded headers, secure cookies,
redirects and CSRF origins, streaming/SSE flushing, upgrade/close, slow clients,
disconnect cancellation and graceful shutdown. No Railway resources are provisioned
or live recipes certified by this document.
