open Httpkit_core

let ok = function Ok x -> x | Error e -> failwith (Error.to_string e)

let measure name size iterations work =
  (* Construct fixtures outside the measurement. Report allocation as well as time:
     host noise makes timing alone a poor early regression signal. *)
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let started = Mtime_clock.counter () in
  for _ = 1 to iterations do
    ignore (Sys.opaque_identity (work ()))
  done;
  let elapsed = Mtime.Span.to_float_ns (Mtime_clock.count started) in
  let allocated = Gc.allocated_bytes () -. allocated in
  Printf.printf
    "{\"case\":%S,\"size\":%d,\"iterations\":%d,\"ns_per_op\":%.3f,\"allocated_bytes_per_op\":%.3f}"
    name size iterations
    (elapsed /. float iterations)
    (allocated /. float iterations)

let () =
  let jobs =
    List.concat_map
      (fun size ->
        let target = "/" ^ String.make (size - 1) 'a' in
        let invalid = String.sub target 0 (size - 1) ^ "\r" in
        [
          ( "target/valid",
            size,
            20000,
            fun () -> ignore (Sys.opaque_identity (Target.of_string target)) );
          ( "target/reject-last",
            size,
            20000,
            fun () -> ignore (Sys.opaque_identity (Target.of_string invalid)) );
        ])
      [ 16; 256; 8192 ]
  in
  let name = ok (Header.Name.of_string "x") in
  let field = ok (Header.of_strings "x" "value") in
  let jobs =
    jobs
    @ List.concat_map
        (fun size ->
          let fields = List.init size (fun _ -> ("x", "value")) in
          let headers = ok (Headers.of_list ~max_fields:101 fields) in
          [
            ( "headers/construct",
              size,
              5000,
              fun () -> ignore (Sys.opaque_identity (Headers.of_list fields)) );
            ( "headers/append",
              size,
              20000,
              fun () -> ignore (Sys.opaque_identity (Headers.add field headers))
            );
            ( "headers/get-all",
              size,
              20000,
              fun () ->
                ignore (Sys.opaque_identity (Headers.get_all name headers)) );
          ])
        [ 1; 10; 100 ]
  in
  Printf.printf
    "{\"scope\":\"core microbenchmarks; no throughput \
     guarantee\",\"compiler\":%S,\"results\":["
    Sys.ocaml_version;
  List.iteri
    (fun i (name, size, iterations, work) ->
      if i > 0 then print_char ',';
      measure name size iterations work)
    jobs;
  print_endline "]}"
