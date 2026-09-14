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
