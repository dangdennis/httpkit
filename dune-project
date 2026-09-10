(lang dune 3.24)
(name http-kit)
(generate_opam_files true)
(maintainers "http-kit maintainers")
(authors "http-kit maintainers")
(package
 (name http-kit-core)
 (synopsis "Validated runtime-independent HTTP values")
 (depends (ocaml (>= 5.2))))
(package
 (name http-kit-http1)
 (synopsis "Bounded incremental HTTP/1.1 codecs")
 (depends http-kit-core ipaddr (ocaml (>= 5.2))))
(package
 (name http-kit-engine)
 (synopsis "Bounded sans-I/O HTTP client and server engines")
 (depends http-kit-core http-kit-http1 (ocaml (>= 5.2))))
(package
 (name http-kit-harness)
 (synopsis "Development-only contract harness for http-kit")
 (depends
  http-kit-core
  http-kit-http1
  http-kit-engine
  (ocaml (and (>= 5.2) (< 5.6)))
  (yojson (= 3.0.0))
  (base64 (= 3.5.2))
  (mtime (= 2.1.0))
  (qcheck-core (= 0.91))
  (alcotest (= 1.9.1))
  (crowbar (= 0.2.2))
  (odoc (= 3.2.1))))
