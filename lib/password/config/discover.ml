module C = Configurator.V1

let () =
  C.main ~name:"httpkit-password" (fun c ->
      let pkg =
        match C.Pkg_config.get c with
        | Some pc -> (
            match C.Pkg_config.query pc ~package:"libargon2" with
            | Some pkg -> pkg
            | None -> C.die "libargon2 development files required")
        | None -> C.die "pkg-config required"
      in
      C.Flags.write_sexp "c_flags.sexp" pkg.cflags;
      C.Flags.write_sexp "c_library_flags.sexp" pkg.libs)
