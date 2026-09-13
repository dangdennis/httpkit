open Common

let resources () =
  let base =
    `Assoc
      [
        ("active", `Int 1);
        ("unexpected_errors", `Int 0);
        ("descriptors", `Int 6);
        ("live_words", `Int 16000);
        ("rss_kib", `Int 16000);
      ]
  in
  let rows = List.init 12 (fun _ -> base) in
  Load.check_resources rows;
  let reject rows =
    require
      (Selftest.rejects (fun () -> Load.check_resources rows))
      "Invalid resource observations accepted"
  in
  reject [];
  List.iter
    (fun (key, value) ->
      reject
        (List.mapi
           (fun i row ->
             if i = 11 then Benchmarks.setj key (`Int value) row else row)
           rows))
    [
      ("active", 2);
      ("unexpected_errors", 1);
      ("descriptors", 12);
      ("live_words", 200000);
      ("rss_kib", 300000);
    ];
  reject
    (List.mapi
       (fun i row ->
         if i >= 9 then Benchmarks.setj "rss_kib" (`Int 60000) row else row)
       rows);
  print_endline
    "PASS resource controls reject leaks, missing observations and RSS growth"

let coordinator () =
  resources ();
  let steps = Validate.personal_steps ~long:true ~skip_afl:true in
  require (List.length steps = 8) "Missing non-AFL steps";
  require
    (List.for_all
       (fun (_, args) ->
         not
           (List.exists
              (fun a -> List.mem a [ "fuzz"; "fuzz-smoke"; "triage-timeout" ])
              args))
       steps)
    "Skip-AFL plan launches AFL";
  require
    (List.exists
       (fun (_, args) -> List.mem "soak" args && List.mem "7200" args)
       steps)
    "Missing full soak";
  require
    (List.for_all
       (fun (_, args) ->
         not
           (List.exists
              (fun a -> List.mem a [ "fuzz"; "fuzz-smoke"; "triage-timeout" ])
              args))
       (Validate.framework_steps true))
    "Framework acceptance launches AFL";
  List.iter
    (fun code ->
      with_temp "httpkit-disconnected-" (fun directory ->
          let input, output = Unix.pipe ~cloexec:true () in
          Unix.close input;
          let err =
            Unix.openfile (directory / "stderr")
              [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
              0o600
          in
          let child =
            Fun.protect
              ~finally:(fun () ->
                Unix.close output;
                Unix.close err)
              (fun () ->
                Process.spawn ~stdout:output ~stderr:err
                  [
                    Sys.executable_name;
                    "coordinator-fixture";
                    string_of_int code;
                    directory;
                  ])
          in
          let status =
            Fun.protect
              ~finally:(fun () -> Process.stop child)
              (fun () -> Process.wait child (monotonic () +. 30.))
          in
          require
            (Process.status_code status = 0 = (code = 0))
            "Disconnected console changed child outcome";
          let rows = json (directory / "steps.json") |> list in
          require
            (List.length rows = 1
            && field "status" (List.hd rows)
               = `String (if code = 0 then "PASS" else "FAIL"))
            "Disconnected console lost durable status"))
    [ 0; 1 ];
  print_endline
    "PASS skip-AFL plans and disconnected-console success/failure preservation"

let cleanup () =
  with_temp "httpkit-invalid-start-" (fun directory ->
      let exe = directory / "invalid-server" and pidfile = directory / "pid" in
      write exe
        ("#!/bin/sh\necho $$ > " ^ Filename.quote pidfile
       ^ "\necho INVALID\nexec sleep 60\n");
      Unix.chmod exe 0o700;
      require
        (Selftest.rejects (fun () ->
             Framework.with_app ~binary:exe ~directory (fun _ ->
                 fail "Unexpected startup success")))
        "Invalid server accepted";
      let pid = int_of_string (String.trim (read pidfile)) in
      let alive =
        try
          Unix.kill pid 0;
          true
        with Unix.Unix_error (Unix.ESRCH, _, _) -> false
      in
      require (not alive) "Invalid-start process leaked");
  with_temp "httpkit-postgres-cleanup-" (fun directory ->
      let directory =
        directory / String.concat "" (List.init 8 (fun _ -> "deep-artifact-"))
      in
      require
        (Selftest.rejects (fun () ->
             Databases.with_postgres directory (fun _ ->
                 fail "Injected failure after startup")))
        "Injected database failure swallowed";
      require
        ((not (Sys.file_exists (directory / "data/postmaster.pid")))
        && Sys.file_exists (directory / "stop.log"))
        "Owned PostgreSQL was not stopped");
  print_endline
    "PASS invalid application startup and failed database scope cleanup"
