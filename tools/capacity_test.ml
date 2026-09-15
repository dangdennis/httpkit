open Devlib
open Common

let rejects f =
  match f () with
  | _ -> failwith "Invalid capacity evidence accepted"
  | exception (Error _ | Failure _) -> ()

let () =
  assert (Capacity.capacities "1,16,64" = [ 1; 16; 64 ]);
  List.iter
    (fun value -> rejects (fun () -> Capacity.capacities value))
    [ ""; "0"; "2"; "128"; "1,1"; "1,01"; "1,"; "1, 16"; "0x40" ];
  let row =
    `Assoc
      [
        ("active", `Int 16);
        ("peak_active", `Int 16);
        ("opened", `Int 18);
        ("closed", `Int 2);
        ("unexpected_errors", `Int 0);
        ("rss_kib", `Int 40000);
      ]
  in
  let check = Capacity.check_snapshot ~capacity:16 ~active:16 in
  check row;
  (* Each corruption breaks a different acceptance invariant. *)
  List.iter
    (fun (key, value) ->
      rejects (fun () -> check (Benchmarks.setj key (`Int value) row)))
    [
      ("active", 15);
      ("peak_active", 17);
      ("peak_active", 15);
      ("opened", 19);
      ("closed", 3);
      ("unexpected_errors", 1);
      ("rss_kib", 524289);
    ];
  rejects (fun () ->
      check
        (row
        |> Benchmarks.setj "opened" (`Int 15)
        |> Benchmarks.setj "closed" (`Int (-1))));
  print_endline "PASS capacity admission and accounting rejection controls"
