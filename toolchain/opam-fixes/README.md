# Local dependency fixes

This opam repository contains one reviewed patch to upstream Caqti PostgreSQL
3.0.1, packaged as `3.0.1+httpkit1`. It is maintained here, not an upstream release.
The original LGPL-3.0-or-later WITH LGPL-3.0-linking-exception license remains in
force. The upstream source archive and local patch have explicit checksums.

When an in-flight query is cancelled, Caqti's reset cleanup may also be cancelled.
Previously the connection's busy flag then remained set, preventing rollback and
disconnect. The patch always clears that flag in a finalizer. It does not shield
query execution or reconnect from cancellation. Our wrapper invalidates the lease
and retires the connection after failure.

Dune consumes this directory when resolving dependencies and embeds the patch in
both checked-in locks. Only this driver version changes; ordinary PostgreSQL SQL,
protocol, TLS and native-client behavior still comes from upstream libraries.

For opam installs of database or SQL-session packages, register this repository
from the httpkit checkout before resolving dependencies:

```sh
opam repository add httpkit-fixes "$PWD/toolchain/opam-fixes" --this-switch
```

Keep the checkout available for repository updates. `httpkit-db-eio` requires
the exact patched version, so central opam alone cannot silently install the
known-broken driver. Pure HTTP packages do not need this repository.

The regression observes `PgSleep` for its own backend before cancelling the
query, then checks joined cleanup, rollback and pool recovery. Keep it when
replacing the patch with a verified upstream release. Do not remove the pin
based on a version bump alone. No upstream issue or patch has been published by
this local work.
