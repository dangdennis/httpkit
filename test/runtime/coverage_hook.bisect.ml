(* Forked children use _exit to avoid inherited parent hooks. Save their native
   counters explicitly; Bisect.write_coverage_data is a JavaScript-only hook. *)
let flush () =
  let prefix = Option.value ~default:"bisect" (Sys.getenv_opt "BISECT_FILE") in
  let path = Printf.sprintf "%s-child-%d.coverage" prefix (Unix.getpid ()) in
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> Bisect.Runtime.dump_counters_exn channel)
