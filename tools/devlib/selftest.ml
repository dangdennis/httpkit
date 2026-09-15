open Common

let rejects f =
  try
    f ();
    false
  with Error _ -> true

let checks () =
  require
    (rejects (fun () -> require false "guard"))
    "Operational guard disabled";
  let rows =
    `List (List.map (fun n -> `Assoc [ ("name", `String n) ]) Release.mutants)
  in
  require
    (Release.inventory rows "name" Release.mutants)
    "Valid inventory rejected";
  List.iter
    (fun rows ->
      require
        (not (Release.inventory rows "name" Release.mutants))
        "Invalid inventory accepted")
    [
      `Null;
      `List [];
      `List [ List.hd (list rows) ];
      `List (List.init 3 (fun _ -> List.hd (list rows)));
      `List [ `Assoc []; `Assoc []; `Assoc [] ];
    ];
  let r =
    Process.run ~check:false
      [ "sh"; "-c"; "printf stdout; printf stderr >&2; exit 7" ]
  in
  require
    (Process.status_code r.status = 7
    && r.stdout = "stdout" && r.stderr = "stderr")
    "Process status/output capture";
  require
    (rejects (fun () -> ignore (Process.run [ "sh"; "-c"; "exit 7" ])))
    "Process failure swallowed";
  with_temp "httpkit-watchdog-" (fun directory ->
      let pidfile = directory / "child" in
      let started = monotonic () in
      require
        (rejects (fun () ->
             ignore
               (Process.run ~timeout:0.1
                  [
                    "sh";
                    "-c";
                    "echo $$ > \"$1\"; exec sleep 30";
                    "watchdog";
                    pidfile;
                  ])))
        "Timeout not enforced";
      require (monotonic () -. started < 3.) "Timeout cleanup stalled";
      let pid = int_of_string (String.trim (read pidfile)) in
      let alive =
        try
          Unix.kill pid 0;
          true
        with Unix.Unix_error (Unix.ESRCH, _, _) -> false
      in
      require (not alive) "Timed-out child leaked");
  let r =
    Network.reference
      "HTTP/1.1 200 OK\r\n\
       Transfer-Encoding: chunked\r\n\
       Set-Cookie: a=1\r\n\
       Set-Cookie: b=2\r\n\
       \r\n\
       3\r\n\
       abc\r\n\
       0\r\n\
       \r\n"
  in
  require
    (r.status = 200 && r.body = "abc"
    && Network.values "set-cookie" r = [ "a=1"; "b=2" ])
    (Printf.sprintf "Independent HTTP reference status=%d body=%S cookies=%s"
       r.status r.body
       (String.concat "," (Network.values "set-cookie" r)));
  print_endline
    "PASS non-removable guards, inventory, process status, timeout cleanup and \
     HTTP reference"

let release () = Release_controls.run ()

let packages () =
  with_temp "httpkit-lock-" (fun directory ->
      List.iter
        (fun p -> copy (root / p) (directory / p))
        [
          "dune-project";
          "dune-workspace";
          "httpkit-harness.opam";
          "httpkit-core.opam";
          "dune.lock";
          "tools/dune-pkg";
          "toolchain/manifest.json";
        ];
      mkdir (directory / ".toolchain/bin");
      Unix.symlink Build.dune (directory / ".toolchain/bin/dune");
      let run version success args =
        let env =
          set
            (set (environment ()) "HARNESS_COMPILER" version)
            "DUNE_CONFIG__PKG" "disabled"
        in
        let r =
          Process.run ~cwd:directory ~env ~check:false
            ((directory / "tools/dune-pkg") :: args)
        in
        require
          (Process.status_code r.status = 0 = success)
          (r.stdout ^ r.stderr);
        r.stdout ^ r.stderr
      in
      ignore (run "5.5.0" true [ "pkg"; "enabled" ]);
      ignore (run "5.5.0" true [ "pkg"; "validate-lockdir"; "dune.lock" ]);
      let p = directory / "dune-project" in
      write p
        (Str.global_replace
           (Str.regexp_string "(yojson (= 3.0.0))")
           "(yojson (= 0.0.0))" (read p));
      ignore (run "5.5.0" false [ "pkg"; "validate-lockdir" ]);
      remove (directory / "dune.lock");
      require
        (contains (run "5.5.0" false [ "build" ]) "Missing dune.lock")
        "Missing lock silently generated";
      require
        (not (Sys.file_exists (directory / "dune.lock")))
        "Lock regenerated";
      List.iter
        (fun v ->
          require
            (contains (run v false [ "build" ]) "HARNESS_COMPILER must be 5.5.0")
            "Invalid compiler accepted")
        [ "invalid"; "5.2.1" ];
      require
        (List.hd (List.rev (Build.command [ "pkg"; "lock" ])) = "dune.lock")
        "Lock default differs";
      print_endline
        "PASS pinned package management and stale/missing/invalid \
         configuration rejection")

let main args =
  match args with
  | [ "release" ] -> release ()
  | [ "packages" ] -> packages ()
  | [ "checks" ] -> checks ()
  | [] ->
      checks ();
      release ();
      packages ()
  | _ -> fail "Unknown self-test"
