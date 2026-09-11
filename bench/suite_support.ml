type job = {
  id : string;
  family : string;
  iterations : int;
  bytes : int;
  work : unit -> unit;
  comparison : string option;
  implementation : string option;
}

let require condition =
  if not condition then failwith "benchmark result mismatch"

let ok = function
  | Ok value -> value
  | Error _ -> failwith "unexpected benchmark error"

let job ?(bytes = 0) ?comparison ?implementation family id iterations work =
  {
    id = family ^ "/" ^ id;
    family;
    iterations;
    bytes;
    work;
    comparison;
    implementation;
  }

let labels job =
  match (job.comparison, job.implementation) with
  | None, None -> []
  | Some comparison, Some implementation ->
      [
        ("comparison", `String comparison);
        ("implementation", `String implementation);
      ]
  | _ -> failwith "incomplete comparison metadata"

let measure ~quick ~min_ms job =
  let iterations =
    if quick then max 1 (job.iterations / 10) else job.iterations
  in
  (* Fixture construction is outside the timer. Work includes result checks so
     an optimized-away operation or a wrong implementation cannot look faster.
     Each sample starts in a fresh process; each case warms before collection. *)
  let warmups = min 3 iterations in
  for _ = 1 to warmups do
    job.work ()
  done;
  (* Calibrate outside the retained timer. Keep the catalog's base iteration
     count separate from the actual count so every process can adapt without
     silently changing the workload identity. Bound calibration and execution. *)
  let base_iterations = iterations in
  let rec calibrate count =
    if min_ms = 0. then count
    else
      let clock = Mtime_clock.counter () in
      for _ = 1 to count do
        job.work ()
      done;
      let ns = Mtime.Span.to_float_ns (Mtime_clock.count clock) in
      if ns >= min_ms *. 1e6 || count >= 10000000 then count
      else calibrate (min 10000000 (count * 2))
  in
  let iterations = calibrate iterations in
  Gc.full_major ();
  let gc = Gc.quick_stat () in
  let before = Gc.allocated_bytes () in
  let clock = Mtime_clock.counter () in
  for _ = 1 to iterations do
    (Sys.opaque_identity job.work) ()
  done;
  let elapsed_ns = Mtime.Span.to_float_ns (Mtime_clock.count clock) in
  let allocated = Gc.allocated_bytes () -. before in
  let after = Gc.quick_stat () in
  require (elapsed_ns > 0. && allocated >= 0.);
  `Assoc
    (labels job
    @ [
        ("id", `String job.id);
        ("family", `String job.family);
        ("iterations", `Int iterations);
        ("base_iterations", `Int base_iterations);
        ("warmups", `Int warmups);
        ("bytes_per_op", `Int job.bytes);
        ("elapsed_ns", `Float elapsed_ns);
        ("ns_per_op", `Float (elapsed_ns /. float iterations));
        ("allocated_bytes_per_op", `Float (allocated /. float iterations));
        ( "minor_collections",
          `Int (after.minor_collections - gc.minor_collections) );
        ( "major_collections",
          `Int (after.major_collections - gc.major_collections) );
      ])

(* Preflight observations are retained in catalog and every process sample. *)
let exclusions : Yojson.Basic.t list ref = ref []
