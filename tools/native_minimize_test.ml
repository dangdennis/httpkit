open Devlib
open Common

let check label result = require result label

let () =
  let binary =
    if Filename.is_relative Sys.argv.(1) then
      Filename.concat (Sys.getcwd ()) Sys.argv.(1)
    else Sys.argv.(1)
  in
  let run ?(attempts = 100) ?(timeout = 1.) input f =
    with_temp "httpkit-minimize-test-" (fun directory ->
        f directory (fun () ->
            Native_minimize.run ~binary ~case:None
              ~source_hash:(fun () -> "fixture")
              ~directory ~attempts ~seconds:30. ~timeout input))
  in
  run "prefixBUGsuffixALT" (fun directory f ->
      let best, minimal, used = f () in
      check "minimized same failure site"
        (best = "BUG" && minimal && used <= 100);
      check "original preserved"
        (read (directory / "original.input") = "prefixBUGsuffixALT");
      check "report marks deletion minimality"
        (field "one_byte_deletion_minimal" (json (directory / "report.json"))
        = `Bool true));
  run ~attempts:3 "prefixBUGsuffix" (fun directory f ->
      let best, minimal, used = f () in
      check "budget retains reproduced input"
        ((not minimal) && best = "prefixBUGsuffix" && used = 3);
      check "budget is not completion"
        (field "status" (json (directory / "report.json"))
        = `String "BUDGET_EXHAUSTED"));
  List.iter
    (fun input ->
      run ~timeout:0.05 input (fun directory f ->
          let failed =
            try
              ignore (f ());
              false
            with Common.Error _ -> true
          in
          check "passing, timed-out and non-property exits rejected" failed;
          check "failed report retained"
            (field "status" (json (directory / "report.json")) = `String "FAIL");
          let probes = list (field "runs" (json (directory / "report.json"))) in
          check "inconclusive probe evidence retained"
            (List.length probes = 1
            && (input = "clean"
               || field "outcome" (List.hd probes) = `String "INCONCLUSIVE"))))
    [ "clean"; "TIMEOUT"; "EXIT" ];
  print_endline "PASS native minimization identity, budget and failure controls"
