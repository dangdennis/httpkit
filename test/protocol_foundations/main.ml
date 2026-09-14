let () =
  if Array.length Sys.argv = 2 then Sys.chdir Sys.argv.(1)
  else
    Support.require
      (Array.length Sys.argv = 1)
      "usage: main [fixture working directory]";
  Mirage_crypto_rng_unix.use_default ();
  let result =
    `Assoc
      [
        ("compiler", `String Sys.ocaml_version);
        ("gzip", Gzip_probe.run ());
        ("zlib", Zlib_probe.run ());
        ("closeable_zlib", Close_probe.run ());
        ("runtime_close", Runtime_close_probe.run ());
        ("tls", Tls_probe.run ());
      ]
  in
  print_endline (Yojson.Basic.pretty_to_string result)
