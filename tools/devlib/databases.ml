open Common

let find_postgres () =
  let candidates = ref [] in
  let add p = if p <> "" then candidates := !candidates @ [ p ] in
  add (Option.value ~default:"" (Sys.getenv_opt "FRAMEWORK_PG_BIN"));
  (try
     add
       (Filename.dirname
          (Unix.realpath
             (String.trim
                (Process.output [ "sh"; "-c"; "command -v postgres" ]))))
   with _ -> ());
  (try add (String.trim (Process.output [ "pg_config"; "--bindir" ]))
   with _ -> ());
  add "/Applications/Postgres.app/Contents/Versions/latest/bin";
  match
    List.find_opt
      (fun p ->
        try
          Process.status_code
            (Process.run ~check:false ~timeout:5.
               [ p / "postgres"; "--version" ])
              .status
          = 0
        with _ -> false)
      !candidates
  with
  | Some p -> p
  | None -> fail "Set FRAMEWORK_PG_BIN to a working PostgreSQL installation"

let port () =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname fd with
      | Unix.ADDR_INET (_, p) -> p
      | _ -> assert false)

let with_postgres directory f =
  mkdir directory;
  let pg = find_postgres () and data = directory / "data" in
  let env =
    environment () |> List.filter (fun (k, _) -> not (starts ~prefix:"PG" k))
  in
  let run name args =
    let result = Process.run ~env ~timeout:120. args in
    write (directory / (name ^ ".log")) (result.stdout ^ result.stderr)
  in
  let close () =
    if Sys.file_exists (data / "postmaster.pid") then
      run "stop" [ pg / "pg_ctl"; "-D"; data; "-m"; "immediate"; "stop"; "-w" ]
  in
  run "initdb" [ pg / "initdb"; "-D"; data; "-A"; "trust"; "--no-locale" ];
  Fun.protect ~finally:close (fun () ->
      let port = port () in
      run "start"
        [
          pg / "pg_ctl";
          "-D";
          data;
          "-l";
          directory / "postgres.log";
          "-o";
          Printf.sprintf "-h 127.0.0.1 -p %d -k ''" port;
          "start";
          "-w";
        ];
      run "createdb"
        [
          pg / "createdb";
          "-h";
          "127.0.0.1";
          "-p";
          string_of_int port;
          "httpkit_test";
        ];
      f (Printf.sprintf "postgresql://127.0.0.1:%d/httpkit_test" port))

let main args =
  let binary = option args "--binary" "" in
  if binary = "" then Build.call [ "build"; "test/db_eio/db_test.exe" ];
  let binary =
    if binary = "" then Build.binary "test/db_eio/db_test.exe"
    else absolute binary
  in
  let directory =
    temp_dir ~parent:(root / "_artifacts/framework") "databases-"
  in
  let digest = Build.source_hash () in
  let steps = ref [] in
  let save_report status extra =
    let report =
      `Assoc
        ([
           ("status", `String status);
           ("source_sha256", `String digest);
           ("steps", strings !steps);
         ]
        @ extra)
    in
    save (directory / "report.json") report;
    report
  in
  let run name cmd =
    let result = Process.run ~timeout:120. cmd in
    write (directory / (name ^ ".log")) (result.stdout ^ result.stderr);
    steps := !steps @ [ name ];
    ignore (save_report "RUNNING" [])
  in
  try
    run "sqlite" [ binary ];
    with_postgres (directory / "postgres") (fun uri ->
        run "postgresql" [ binary; uri ]);
    require
      (Build.source_hash () = digest)
      "Sources changed during database validation";
    let report = save_report "PASS" [] in
    save (root / "_artifacts/framework/databases.json") report;
    print_endline
      "PASS PostgreSQL and SQLite; isolated PostgreSQL instance stopped"
  with exn ->
    ignore (save_report "FAIL" [ ("error", `String (Printexc.to_string exn)) ]);
    raise exn
