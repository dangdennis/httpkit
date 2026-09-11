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

let measure ~quick job =
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
