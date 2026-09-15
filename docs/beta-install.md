# Installing the beta candidate from source

Package version: `0.1.0~beta1`, under [MIT](../LICENSE). The planned GitHub
prerelease is `v0.1.0-beta.1`; it has not been published. There is no central opam
submission yet. Publication requires owner review after the [beta plan](beta-plan.md).
WebSockets remain experimental.

## Install selected packages

Use opam 2.5 and OCaml 5.5.0. Start in an httpkit checkout or extracted source
archive. Keep `toolchain/opam-fixes` and both Dune lock directories in that source.
If you already have a suitable switch, use it; otherwise create one:

```sh
opam switch create httpkit-beta ocaml-base-compiler.5.5.0
eval "$(opam env --switch=httpkit-beta --set-switch)"
```

Select the tested repository snapshot and local PostgreSQL fix for this switch:

```sh
opam repository add httpkit-tested \
  'git+https://github.com/ocaml/opam-repository.git#5d711cd97e038d93464ab855e041c0ff624c9d07' \
  --this-switch
opam repository add httpkit-fixes "$PWD/toolchain/opam-fixes" --this-switch
opam repository set-repos httpkit-fixes httpkit-tested --this-switch
opam pin add --kind=path --no-action .
opam install dune.3.24.1 httpkit-eio eio_main
```

The pin discovers all 17 package definitions; `--no-action` avoids installing the
whole workspace. Install only what your application uses. `httpkit-harness` is
for development and is unnecessary for applications. An Eio executable selects
`eio_main`; `httpkit-eio` itself needs only Eio interfaces. For a pure codec, use
`opam install httpkit-http1`. Optional packages include `httpkit-cookie`,
`httpkit-password`, `httpkit-db-eio`, `httpkit-session-eio` and `httpkit-oidc-eio`.

Keep the pinned source directory available for updates. Database and SQL-session
packages require the exact local driver `caqti-driver-postgresql.3.0.1+httpkit1`;
central opam alone cannot supply it. See [dependency fixes](../toolchain/opam-fixes/README.md).
Native dependencies include a C toolchain and, depending on selected packages,
pkg-config, GMP, libffi, libargon2, libpq and SQLite. The local validation used
existing system libraries and did not install OS packages automatically.

## Check application composition

In a separate application directory, create `dune-project`:

```lisp
(lang dune 3.24)
(name httpkit_example)
```

Create `dune-workspace` with `(lang dune 3.24)` and `(pkg disabled)` to use the
opam switch, and `dune`:

```lisp
(executable (name main) (modes byte exe) (libraries httpkit-eio))
```

Create `main.ml`:

```ocaml
let () =
  let handler _ = Httpkit_eio.reply (Httpkit.Reply.text "ok") in
  let _application =
    Httpkit_eio.routes
      [ Httpkit_eio.route Httpkit_core.Method.get "/" handler ]
  in
  print_endline "httpkit application assembled"
```

Run `dune exec --root . ./main.exe`. This checks the installed API; listener and
lifetime setup are covered in the [application guide](framework.md).

## Retained installation evidence

On 2026-09-15, all 16 runtime packages installed from a Git archive of `a21d8ee`
on macOS arm64 into a fresh opam root, with Dune 3.24.1 and the repository snapshot
above. The test reused an existing OCaml 5.5.0 compiler through `ocaml-system`;
it was not a fresh compiler build. The archive SHA-256 was
`379b0bab6149558d027380a1f51f683773fe8580daae971c72eb2843a47c6b6b`.
This identifies the locally generated tar, not a future GitHub release download.

Twelve existing consumer programs passed in native and bytecode modes, covering
core, HTTP/1, engine, router, middleware, application helpers, Eio, Lwt, SQLite,
cookies/passwords/OIDC, SQL sessions and OIDC flows. `eio_main` was added explicitly
for executable tests. Bytecode execution with the reused compiler required
`CAML_LD_LIBRARY_PATH` to point to the isolated switch's `lib/stublibs` directory.
The PostgreSQL driver installed and linked; this run used SQLite databases and
does not replace the PostgreSQL fault or sustained campaigns.

The [installation inventory](beta-install-inventory.md) records the selected
versions and declared licenses. Opam resolution is separate from the Dune locks
and selected some different versions. Installed-consumer success is not an
advisory scan, native-library inventory, complete license review, Linux install
check, final candidate archive check, or production approval.

The source MIT license does not replace dependency licenses. Preserve the Caqti
LGPL linking-exception notice and the bundled `closeable_zlib` test fixture's ISC
notice. Complete distribution notices, final archive checks and release notes
remain publication gates. Report vulnerabilities using [SECURITY.md](../SECURITY.md).
