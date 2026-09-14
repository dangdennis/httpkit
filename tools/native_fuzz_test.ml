open Devlib

let () =
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
