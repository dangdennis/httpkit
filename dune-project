(lang dune 3.24)
(name http-kit)
(generate_opam_files true)
(maintainers "http-kit maintainers")
(authors "http-kit maintainers")
(package
 (name http-kit-core)
 (synopsis "Validated runtime-independent HTTP values")
 (depends (ocaml (= 5.5.0))))
(package
 (name http-kit-http1)
 (synopsis "Bounded incremental HTTP/1.1 codecs")
 (depends http-kit-core ipaddr (ocaml (= 5.5.0))))
(package
 (name http-kit-engine)
 (synopsis "Bounded sans-I/O HTTP client and server engines")
 (depends http-kit-core http-kit-http1 (ocaml (= 5.5.0))))
(package
 (name http-kit-eio)
 (synopsis "Native Eio adapter for HTTP primitives")
 (depends http-kit-core http-kit-engine eio cstruct mtime (ocaml (= 5.5.0))))
(package
 (name http-kit-lwt)
 (synopsis "Native Lwt adapter for HTTP primitives")
 (depends http-kit-core http-kit-engine lwt mtime (ocaml (= 5.5.0))))
(package
 (name http-kit-middleware)
 (synopsis "Runtime-independent middleware with typed context transitions")
 (depends http-kit-core (ocaml (= 5.5.0))))
(package
 (name http-kit-router)
 (synopsis "Bounded pure routing over raw HTTP paths")
 (depends http-kit-core (ocaml (= 5.5.0))))
(package
 (name http-kit-harness)
 (synopsis "Development-only contract harness for http-kit")
 (depopts bisect_ppx)
 (depends
  http-kit-core
  http-kit-http1
  http-kit-engine
  http-kit-eio
  http-kit-lwt
  http-kit-middleware
  http-kit-router
  eio_main
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
