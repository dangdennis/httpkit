open Common

let main () =
  let digest = Build.source_hash () in
  Build.call
    [
      "build";
      "test/protocol_foundations/main.exe";
      "test/protocol_foundations/main.bc";
    ];
  let run suffix =
    Build.output
      [
        "exec";
        "--";
        "./test/protocol_foundations/main." ^ suffix;
        root / "test/protocol_foundations";
      ]
    |> Yojson.Basic.from_string
  in
  let native = run "exe" and bytecode = run "bc" in
  require
    (Build.source_hash () = digest)
    "Sources changed during protocol spikes";
  Build.record "protocol-foundations/report.json"
    [
      ("status", `String "EXPERIMENTS_COMPLETE");
      ("production_gate", `String "NOT_READY");
      ("native", native);
      ("bytecode", bytecode);
      ("afl", `String "SKIPPED_BY_REQUEST");
    ];
  print_endline
    "Protocol experiments complete; production integration remains NOT_READY."
