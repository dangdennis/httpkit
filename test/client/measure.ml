(* Whole local scenario cost: client + fixture server + connection/runtime setup.
   Never label this client-only throughput. Warm up before retained-heap checks.
   Backtraces and sparse progress logging stay enabled for reproducible diagnostics. *)
let enabled () = Sys.getenv_opt "HTTPKIT_CLIENT_BENCH" = Some "1"
let fd_count () = Array.length (Sys.readdir "/dev/fd")

let measure ?(body_bytes = 200000) ?(requests = 1) ?(case = "fetch") runtime
    scenario =
  List.iter
    (fun key ->
      if Sys.getenv_opt key <> None then
        invalid_arg ("unset measurement override: " ^ key))
    [
      "BISECT_FILE";
      "DUNE_INSTRUMENT_WITH";
      "OCAMLPARAM";
      "OCAMLRUNPARAM";
      "CAMLRUNPARAM";
    ];
  let iterations =
    match Sys.getenv_opt "HTTPKIT_CLIENT_ITERATIONS" with
    | None -> 20
    | Some n -> int_of_string n
  in
  if iterations < 1 || iterations > 10000 then
    invalid_arg "iterations: 1..10000";
  List.iter
    (fun tls ->
      Printf.eprintf "Client %s %s tls=%b: warmup\n%!" runtime case tls;
      for _ = 1 to 3 do
        scenario tls `Large
      done;
      Gc.full_major ();
      let descriptors = fd_count () in
      let before = (Gc.stat ()).live_words in
      let allocations = Gc.allocated_bytes () in
      let start = Mtime_clock.counter () in
      let times =
        Array.init iterations (fun i ->
            let start = Mtime_clock.counter () in
            scenario tls `Large;
            let milliseconds =
              Mtime.Span.to_float_ns (Mtime_clock.count start) /. 1e6
            in
            if (i + 1) mod 100 = 0 || i + 1 = iterations then
              Printf.eprintf "Client %s %s tls=%b: %d/%d\n%!" runtime case tls
                (i + 1) iterations;
            milliseconds)
      in
      let elapsed = Mtime.Span.to_float_ns (Mtime_clock.count start) /. 1e9 in
      let allocated = Gc.allocated_bytes () -. allocations in
      Gc.full_major ();
      let retained = (Gc.stat ()).live_words - before in
      let fd_delta = fd_count () - descriptors in
      assert (fd_delta = 0);
      Array.sort Float.compare times;
      Printf.printf
        "{\"compiler\":%S,\"profile\":\"uninstrumented\",\"runtime\":%S,\"tls\":%b,\"scope\":\"whole-local-scenario\",\"iterations\":%d,\"case\":%S,\"requests_per_iteration\":%d,\"body_bytes\":%d,\"fd_delta\":%d,\"seconds\":%.6f,\"p50_ms\":%.6f,\"p95_ms\":%.6f,\"allocated_bytes_per_request\":%.0f,\"retained_words\":%d}\n\
         %!"
        Sys.ocaml_version runtime tls iterations case requests body_bytes
        fd_delta elapsed
        times.(iterations / 2)
        times.(min (iterations - 1) (iterations * 95 / 100))
        (allocated /. float (iterations * requests))
        retained;
      if
        case = "fetch"
        && allocated /. float iterations
           > if tls then 7_300_000. else 2_000_000.
      then failwith "client fetch allocation regression";
      (* A generous deterministic leak tripwire, not a performance target. *)
      if retained > 131072 then
        failwith "client scenario retained > 1MiB after GC")
    [ false; true ]

let run ?body_bytes ?requests ?case runtime scenario =
  let iterations =
    match Sys.getenv_opt "HTTPKIT_CLIENT_ITERATIONS" with
    | None -> 20
    | Some n -> int_of_string n
  in
  if iterations < 1 || iterations > 10000 then
    invalid_arg "iterations: 1..10000";
  match
    Harness_runtime.Watchdog.run
      ~seconds:(30. +. (5. *. float iterations))
      (fun () ->
        Printexc.record_backtrace true;
        try measure ?body_bytes ?requests ?case runtime scenario
        with e ->
          prerr_endline (Printexc.to_string e);
          Printexc.print_backtrace stderr;
          raise e)
  with
  | Exited 0 -> ()
  | _ -> failwith "client measurement failed or timed out"
