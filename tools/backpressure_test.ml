open Devlib
open Common

let rejects f =
  match f () with
  | _ -> failwith "Invalid backpressure evidence accepted"
  | exception (Error _ | Failure _) -> ()

let () =
  let c =
    `Assoc
      [
        ("id", `Int 1);
        ("written", `Int 20000);
        ("produced", `Int 8192);
        ("producing", `Bool true);
        ("sending", `Bool true);
      ]
  in
  let row =
    `Assoc
      [
        ("active", `Int 1);
        ("opened", `Int 3);
        ("closed", `Int 2);
        ("peak_active", `Int 1);
        ("unexpected_errors", `Int 0);
        ("violations", `Int 0);
        ("failures", `Assoc []);
        ("queue_peak", `Int 32768);
        ("queues", `List [ `Int 32768 ]);
        ("connections", `List [ c ]);
      ]
  in
  Backpressure.check ~capacity:1 row;
  let timeout phase id seconds =
    `Assoc
      [
        ("failures", `Assoc [ (phase, `Int 1) ]);
        ( "closed_connections",
          `List
            [
              `Assoc [ ("id", `Int id); ("write_idle_seconds", `Float seconds) ];
            ] );
      ]
  in
  Backpressure.check_write_timeout ~capacity:1 row (timeout "write" 1 30.);
  List.iter
    (fun after ->
      rejects (fun () -> Backpressure.check_write_timeout ~capacity:1 row after))
    [
      timeout "idle" 1 30.;
      timeout "application" 1 30.;
      timeout "write" 2 30.;
      timeout "write" 1 20.;
      timeout "write" 1 40.;
      timeout "write" 1 nan;
    ];
  assert (Backpressure.blocked ~capacity:1 row);
  List.iter
    (fun (key, value) ->
      rejects (fun () ->
          Backpressure.check ~capacity:1 (Benchmarks.setj key value row)))
    [
      ("active", `Int 2);
      ("closed", `Int 1);
      ("peak_active", `Int 2);
      ("unexpected_errors", `Int 1);
      ("violations", `Int 1);
      ("queue_peak", `Int 32769);
      ("connections", `List []);
      ("failures", `Assoc [ ("unexpected", `Int 1) ]);
    ];
  List.iter
    (fun (key, value) ->
      let changed =
        Benchmarks.setj "connections"
          (`List [ Benchmarks.setj key value c ])
          row
      in
      assert (not (Backpressure.blocked ~capacity:1 changed)))
    [
      ("producing", `Bool false);
      ("sending", `Bool false);
      ("produced", `Int 0);
      ("produced", `Int Backpressure.stream_bytes);
    ];
  assert (
    not
      (Backpressure.blocked ~capacity:1
         (Benchmarks.setj "queues" (`List [ `Int 0 ]) row)));
  let changed =
    Benchmarks.setj "connections"
      (`List [ Benchmarks.setj "written" (`Int 20001) c ])
      row
  in
  assert (Backpressure.progress changed <> Backpressure.progress row);
  let first = Benchmarks.setj "snapshot_seconds" (`Float 1.) row in
  assert (
    Backpressure.stable ~capacity:1 first
      (Benchmarks.setj "snapshot_seconds" (`Float 2.) row));
  assert (not (Backpressure.stable ~capacity:1 first first));
  assert (
    not
      (Backpressure.stable ~capacity:1 first
         (Benchmarks.setj "snapshot_seconds" (`Float 2.) changed)));
  let delayed = ref false in
  rejects (fun () ->
      Backpressure.wait ~timeout:0.05
        (fun () ->
          delayed := true;
          sleep 0.1;
          row)
        (fun _ -> true));
  assert !delayed;
  let malformed wire =
    let fd, peer = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let c = Network.of_fd fd in
    Fun.protect
      ~finally:(fun () ->
        Network.close c;
        Unix.close peer)
      (fun () ->
        ignore (Unix.write_substring peer wire 0 (String.length wire));
        Unix.shutdown peer Unix.SHUTDOWN_SEND;
        rejects (fun () -> Backpressure.consume c))
  in
  malformed "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n0\r\n\r\n";
  malformed
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\ny\r\n0\r\n\r\n";
  malformed "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2001\r\n";
  print_endline
    "PASS blocked-producer evidence and bounded response rejection controls"
