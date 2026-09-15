open Devlib
open Common

let rejects f =
  match f () with
  | _ -> failwith "Invalid endpoint profile accepted"
  | exception (Error _ | Failure _) -> ()

let () =
  assert (Endpoint_profile.concurrencies "1,4,8,16,64" = [ 1; 4; 8; 16; 64 ]);
  List.iter
    (fun value -> rejects (fun () -> Endpoint_profile.concurrencies value))
    [
      "";
      "0";
      "65";
      "-1";
      "+1";
      "1,1";
      "01,1";
      "1,";
      "1,,2";
      "1, 4";
      "0x40";
      "999999999999999999999999999";
    ];
  let sample rss descriptors =
    `Assoc
      [
        ("active", `Int 1);
        ("unexpected_errors", `Int 0);
        ("live_words", `Int 1000);
        ("rss_kib", `Int rss);
        ("descriptors", `Int descriptors);
      ]
  in
  let rows = [ sample 300000 10 ] in
  rejects (fun () -> Load.check_resources rows);
  Load.check_resources ~rss_limit_kib:524288 rows;
  rejects (fun () ->
      Load.check_resources ~rss_limit_kib:524288 [ sample 524289 10 ]);
  rejects (fun () ->
      Load.check_resources ~rss_limit_kib:524288
        [
          sample 300000 10; sample 300000 10; sample 300000 10; sample 300000 13;
        ]);
  print_endline "PASS endpoint capacity configuration preserves resource limits"
