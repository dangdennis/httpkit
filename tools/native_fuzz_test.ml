open Devlib

let () =
  let path = Filename.temp_file "httpkit-native-input-" "" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      Common.write path "\000\255raw\r\n";
      assert (Native_fuzz.read_input path = "\000\255raw\r\n");
      Common.write path (String.make 65537 'x');
      (match Native_fuzz.read_input path with
      | _ -> failwith "Oversized replay accepted"
      | exception Common.Error _ -> ());
      Sys.remove path;
      Unix.mkfifo path 0o600;
      match Native_fuzz.read_input path with
      | _ -> failwith "FIFO replay accepted"
      | exception Common.Error _ -> ());
  Native_fuzz.check_log "request: PASS\n\n";
  let counts =
    `Assoc
      [
        ("schema", `Int 1);
        ("generated", `Int 3);
        ("checked", `Int 2);
        ("skipped", `Int 1);
        ("failed", `Int 0);
        ("maximum_input_bytes", `Int 1025);
        ("maximum_checked_input_bytes", `Int 1024);
      ]
  in
  Native_fuzz.check_counts ~rounds:3 counts;
  let rejects_counts data =
    match Native_fuzz.check_counts ~rounds:3 data with
    | () -> failwith "Invalid native counts accepted"
    | exception Common.Error _ -> ()
  in
  List.iter
    (fun (key, value) -> rejects_counts (Benchmarks.setj key value counts))
    [
      ("generated", `Int 2);
      ("checked", `Int 0);
      ("checked", `Int 4);
      ("skipped", `Int (-1));
      ("skipped", `Int 0);
      ("failed", `Int 1);
      ("maximum_input_bytes", `Int 65537);
      ("maximum_checked_input_bytes", `Int 1026);
      ("maximum_checked_input_bytes", `Int (-1));
      ("schema", `Int 2);
    ];
  rejects_counts (`Assoc (("checked", `Int 2) :: Common.assoc counts));
  let binary =
    if Filename.is_relative Sys.argv.(1) then
      Filename.concat (Sys.getcwd ()) Sys.argv.(1)
    else Sys.argv.(1)
  in
  Common.with_temp "httpkit-accounting-test-" (fun directory ->
      let stats = Filename.concat directory "stats.json" in
      let env =
        Build.environment ()
        |> List.filter (fun (key, _) ->
            not
              (Common.starts ~prefix:"HTTP_KIT_FUZZ_" key
              || Common.starts ~prefix:"AFL_" key
              || Common.starts ~prefix:"__AFL" key))
      in
      let env =
        Common.set
          (Common.set env "HTTP_KIT_FUZZ_CASE" "server")
          "HTTP_KIT_FUZZ_STATS" stats
      in
      let result = Process.run ~env [ binary; "-r"; "200"; "-s"; "42" ] in
      Native_fuzz.check_log result.stdout;
      let data = Common.json stats in
      Native_fuzz.check_counts ~rounds:200 data;
      assert (Common.int (Common.field "skipped" data) > 0);
      assert (Common.int (Common.field "maximum_checked_input_bytes" data) > 64);
      let input = Filename.concat directory "oversized.input" in
      Common.write input (String.make 1025 'x');
      let raw_stats = Filename.concat directory "raw-stats.json" in
      let env =
        Common.set
          (Common.set env "HTTP_KIT_FUZZ_INPUT" input)
          "HTTP_KIT_FUZZ_STATS" raw_stats
      in
      let result = Process.run ~env ~check:false [ binary ] in
      assert (Process.status_code result.status <> 0);
      assert (Common.field "checked" (Common.json raw_stats) = `Int 0);
      assert (Common.field "skipped" (Common.json raw_stats) = `Int 1));
  List.iter
    (fun log ->
      let rejected =
        try
          Native_fuzz.check_log log;
          false
        with Common.Error _ -> true
      in
      if not rejected then failwith "Invalid native fuzz evidence accepted")
    [
      "";
      "request: BAD\n";
      "request: FAIL\n";
      "request: PASS\nresponse: PASS\n";
      "request: PASS\nFAIL\n";
      "request: PASS with warnings\n";
    ];
  print_endline
    "PASS native fuzz evidence rejects empty, bad and ambiguous runs"
