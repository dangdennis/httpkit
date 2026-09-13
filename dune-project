(lang dune 3.24)
(name httpkit)
(generate_opam_files true)
(maintainers "httpkit maintainers")
(authors "httpkit maintainers")
(package
 (name httpkit-core)
 (synopsis "Validated runtime-independent HTTP values")
 (depends (ocaml (= 5.5.0))))
(package
 (name httpkit-http1)
 (synopsis "Bounded incremental HTTP/1.1 codecs")
 (depends httpkit-core ipaddr (ocaml (= 5.5.0))))
(package
 (name httpkit-engine)
 (synopsis "Bounded sans-I/O HTTP client and server engines")
 (depends httpkit-core httpkit-http1 (ocaml (= 5.5.0))))
(package
 (name httpkit-transport-eio)
 (synopsis "Native Eio adapter for HTTP primitives")
 (depends httpkit-core httpkit-engine eio cstruct mtime (ocaml (= 5.5.0))))
(package
 (name httpkit-transport-lwt)
 (synopsis "Native Lwt adapter for HTTP primitives")
 (depends httpkit-core httpkit-engine lwt mtime (ocaml (= 5.5.0))))
(package
 (name httpkit-middleware)
 (synopsis "Runtime-independent middleware with typed context transitions")
 (depends httpkit-core (ocaml (= 5.5.0))))
(package
 (name httpkit-router)
 (synopsis "Bounded pure routing over raw HTTP paths")
 (depends httpkit-core (ocaml (= 5.5.0))))
(package
 (name httpkit)
 (synopsis "Bounded web application primitives")
 (depends httpkit-core yojson base64 digestif eqaf (ocaml (= 5.5.0))))
(package
 (name httpkit-eio)
 (synopsis "Composable Eio web application server")
 (depends httpkit httpkit-router httpkit-middleware httpkit-transport-eio eio_main ipaddr base64 yojson mtime cstruct (ocaml (= 5.5.0))))
(package
 (name httpkit-db-eio)
 (synopsis "Eio database transactions and migrations")
 (depends caqti-eio caqti-driver-postgresql caqti-driver-sqlite3 digestif (ocaml (= 5.5.0))))
(package
 (name httpkit-cookie)
 (synopsis "Authenticated encrypted cookie sessions")
 (depends httpkit mirage-crypto mirage-crypto-rng base64 yojson eqaf (ocaml (= 5.5.0))))
(package
 (name httpkit-password)
 (synopsis "Bounded Argon2id password hashing")
 (depends argon2 dune-configurator conf-pkg-config (ocaml (= 5.5.0))))
(package
 (name httpkit-session-eio)
 (synopsis "Durable Eio sessions for PostgreSQL and SQLite")
 (depends httpkit httpkit-eio httpkit-db-eio base64 eqaf caqti-eio digestif (ocaml (= 5.5.0))))
(package
 (name httpkit-oidc)
 (synopsis "Runtime-neutral OpenID Connect client policy")
 (depends httpkit oidc jose uri yojson base64 eqaf ptime (ocaml (= 5.5.0))))
(package
 (name httpkit-oidc-eio)
 (synopsis "Bounded Eio OpenID Connect login flows")
 (depends httpkit-oidc httpkit-eio eio (ocaml (= 5.5.0))))
(package
 (name httpkit-lwt)
 (synopsis "Composable Lwt web application server")
 (depends httpkit httpkit-router httpkit-middleware httpkit-transport-lwt lwt base64 yojson ipaddr (ocaml (= 5.5.0))))
(package
 (name httpkit-harness)
 (synopsis "Development-only contract harness for httpkit")
 (depopts bisect_ppx)
 (depends
  httpkit-core
  httpkit-http1
  httpkit-engine
  httpkit-transport-eio
  httpkit-transport-lwt
  httpkit-middleware
  httpkit-router
  httpkit
  httpkit-eio
  httpkit-db-eio
  httpkit-cookie
  httpkit-password
  httpkit-session-eio
  httpkit-oidc
  httpkit-oidc-eio
  httpkit-lwt
  eio_main
  (routes (= 2.0.0))
  (httpaf (= 0.7.1))
  (httpun (= 0.2.0))
  angstrom
  (ocaml (= 5.5.0))
  (yojson (= 3.0.0))
  (base64 (= 3.5.2))
  (mtime (= 2.1.0))
  (qcheck-core (= 0.91))
  (alcotest (= 1.9.1))
  (crowbar (= 0.2.2))
  (odoc (= 3.2.1))))

; Pinned upstream PR #448: modern PPX AST and Cmdliner 2 compatibility.
; Development coverage only; not a production dependency.
(pin
 (url "git+https://github.com/patricoferris/bisect_ppx.git#7061d643ff492b0045796357ee6917ded21fb1f0")
 (package (name bisect_ppx) (version 2.8.3+git.7061d64)))
