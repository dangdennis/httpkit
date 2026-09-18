# Start an application from GitHub

This guide creates an Eio application with a few routes and either SQLite or
PostgreSQL. The same application code supports both databases. See
[current validation status](status.md) before adopting a version: the libraries
are experimental and the runtime/socket hang remains unresolved.

## 1. Create the repository and pin httpkit

Install Git, opam 2.5, a C toolchain, pkg-config, GMP, libffi, SQLite and PostgreSQL
development libraries. The database package links both drivers, even when you
use only SQLite. Install OS packages through your usual environment setup.

Choose the full commit SHA that your team has reviewed, from
[the GitHub repository](https://github.com/dangdennis/httpkit). Use a commit that
contains `examples/starter/main.ml`; do not leave deployed builds tracking `main`.

```sh
mkdir my-httpkit-app
cd my-httpkit-app
git init
HTTPKIT_REV='<full-reviewed-commit-sha>'
git submodule add https://github.com/dangdennis/httpkit.git vendor/httpkit
git -C vendor/httpkit checkout --detach "$HTTPKIT_REV"
git add vendor/httpkit
```

The Git submodule records the exact library revision. Colleagues can fetch both
repositories with `git clone --recurse-submodules <your-application-repository>`.
After changing an existing checkout, run `git submodule update --init --recursive`.

## 2. Install the selected packages

Create a local opam switch and use the tested dependency repository plus the
local PostgreSQL driver fix:

```sh
opam switch create . ocaml-base-compiler.5.5.0
eval "$(opam env --switch=. --set-switch)"
opam repository add httpkit-tested \
  'git+https://github.com/ocaml/opam-repository.git#5d711cd97e038d93464ab855e041c0ff624c9d07' \
  --this-switch
opam repository add httpkit-fixes "$PWD/vendor/httpkit/toolchain/opam-fixes" --this-switch
opam repository set-repos httpkit-fixes httpkit-tested --this-switch
opam pin add --kind=path --no-action ./vendor/httpkit
opam install dune.3.24.1 httpkit-eio httpkit-db-eio eio_main
```

The path pin discovers all package definitions, but installs only the requested
packages and dependencies. You do not need `httpkit-harness`. The pinned
`caqti-driver-postgresql.3.0.1+httpkit1` comes from the local fixes repository;
do not replace it with an arbitrary upstream version. Keep the submodule checked
out. See [installation details](beta-install.md) for native dependencies and caveats.

For an application without a database, omit `httpkit-db-eio`. For outbound HTTP,
add `httpkit-client-eio` and follow the [streaming client guide](client.md).

## 3. Add Dune files and the starter

Create `dune-project`:

```lisp
(lang dune 3.24)
(name my_httpkit_app)
```

Create `dune-workspace` so Dune uses the opam switch:

```lisp
(lang dune 3.24)
(pkg disabled)
```

Create `dune`. Excluding `vendor` prevents Dune from building the pinned library
checkout as a second copy of the application workspace:

```lisp
(dirs :standard \ vendor)
(executable
 (name main)
 (modes exe)
 (libraries httpkit-eio httpkit-db-eio eio_main))
```

Copy the complete [starter source](../examples/starter/main.ml):

```sh
cp vendor/httpkit/examples/starter/main.ml main.ml
printf '_opam/\n_build/\n.env\n*.db\n*.db-*\n' > .gitignore
dune build main.exe
```

The starter owns its listener and database pool inside an Eio switch. It binds
`127.0.0.1`, installs its initial migration, and closes the pool on shutdown.
SIGINT/SIGTERM stop admission and allow HTTP cleanup. It logs generic failures
without printing database credentials or request bodies.

Use the native `.exe` build for this guide. The installed-package check found a
PostgreSQL startup crash in the pinned driver's bytecode C binding; SQLite
bytecode passed, but PostgreSQL bytecode is not supported by this recipe. See
[validation status](status.md) for the retained finding.

## 4. Choose a database and run

For SQLite, use an absolute file URI. The directory must already exist:

```sh
export DATABASE_URL="sqlite3:$PWD/app.db"
PORT=8080 dune exec ./main.exe
```

For PostgreSQL, create an application database and role using your database
operator's normal process. For an existing local development server:

```sh
export DATABASE_URL='postgresql://app_user:development_password@127.0.0.1:5432/app_db'
PORT=8080 dune exec ./main.exe
```

Those credentials are illustrative. Use your secret store for real credentials;
percent-encode reserved URI characters. For a remote PostgreSQL service, use its
verified TLS configuration and CA settings rather than copying the local URI.
Connection options are handled by Caqti/libpq. Never commit real connection strings.

## 5. Try the routes

In another terminal:

```sh
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/hello/Ada
curl --fail -X POST http://127.0.0.1:8080/notes \
  -H 'Content-Type: application/json' --data '{"body":"First note"}'
curl --fail http://127.0.0.1:8080/notes
```

Expected responses: `ok`, `Hello Ada`, `Saved` (HTTP 201), and `["First note"]`
for a fresh database. An empty or malformed note returns HTTP 400. Unknown routes
return 404; unsupported methods return 405. Restart the app with the same database
to verify that the note persists. GET `/notes` returns at most 100 notes.

## How the pieces fit

A route returns an application reply:

```ocaml
App.route Httpkit_core.Method.get "/health"
  (fun _ -> App.reply (Httpkit.Reply.text "ok\n"))
```

SQL values are typed parameters, not string concatenation:

```ocaml
module Query = struct
  open Caqti.Templater
  let insert = static T.(string -->. unit) "INSERT INTO notes(body) VALUES (?)"
end

let save_note db body =
  Httpkit_db_eio.transaction db (fun (module C : Caqti_eio.CONNECTION) ->
      Caqti_eio.or_fail (C.exec Query.insert body))
```

Transactions commit when the callback returns and roll back on errors or
cancellation. Do not retain the connection outside the callback or run nested
transactions. A lost connection during commit can leave the outcome unknown;
application reconciliation is still required.

The starter uses the same version-1 `CREATE TABLE` migration for both backends.
Add a new migration version when the schema changes; do not edit an already-applied
migration. PostgreSQL has a statement timeout. SQLite has bounded lock waiting,
not the same statement-deadline guarantee.

## Before broader internal use

This is a local wiring example, not an authenticated notes service. Add your
application's authentication/authorization before exposing its routes. Configure
TLS and trusted proxy behavior for the actual environment, and choose the listener
address deliberately. Do not trust forwarded headers from arbitrary clients.

The example limits admission to 16 connections, request bodies to 4 KiB, queued
output to 32 KiB and request duration to 30 seconds. Its database pool has four
connections and 16 waiters. Choose and measure limits for your handlers; these
numbers are not a total process-memory budget.

Before broad rollout, resolve the [known hang's applicability](profiling-hang.md),
validate the pinned candidate on the target platform, test shutdown and rollback,
and configure health/error/latency/resource monitoring. SQLite needs persistent
storage and a backup policy; PostgreSQL needs its own migration/backup/recovery
plan. Keep the previous application build and dependency revision for rollback.
Public release gates and the deferred API review remain unchanged.
