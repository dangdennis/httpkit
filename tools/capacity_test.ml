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
  assert (Slow_client.select "body,header" = [ "body"; "header" ]);
  List.iter
    (fun value -> rejects (fun () -> Slow_client.select value))
    [ ""; "header,header"; "unknown"; "body," ];
  let with_socket f =
    let fd, peer = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Unix.set_nonblock fd;
    let c = Network.of_fd fd in
    Fun.protect
      ~finally:(fun () ->
        Network.close c;
        Unix.close peer)
      (fun () -> f c peer)
  in
  let wait c minimum deadline =
    Slow_client.await_closed ~minimum ~deadline [| Some c |]
      [| monotonic () |]
      (fun () -> ())
  in
  with_socket (fun c peer ->
      Unix.shutdown peer Unix.SHUTDOWN_SEND;
      rejects (fun () -> wait c 10. (monotonic () +. 1.)));
  with_socket (fun c _ -> rejects (fun () -> wait c 0. (monotonic () -. 1.)));
  with_socket (fun c peer ->
      Unix.shutdown peer Unix.SHUTDOWN_SEND;
      let deadline = monotonic () +. 0.2 and sampled = ref false in
      rejects (fun () ->
          Slow_client.await_closed ~minimum:0. ~deadline [| Some c |]
            [| monotonic () |]
            (fun () ->
              sampled := true;
              while monotonic () <= deadline do
                sleep 0.01
              done));
      assert !sampled);
  with_socket (fun c peer ->
      ignore (Unix.write_substring peer "error" 0 5);
      Unix.shutdown peer Unix.SHUTDOWN_SEND;
      let row = wait c 0. (monotonic () +. 1.) in
      assert (field "response_bytes" row = `List [ `Int 5 ]);
      assert c.closed);
  print_endline
    "PASS capacity accounting and slow-client deadline rejection controls"
