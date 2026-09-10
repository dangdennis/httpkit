open Http_kit_core
open Http_kit_http1

let () =
  Printf.printf "{\"compiler\":%S,\"results\":[" Sys.ocaml_version;
  List.iteri
    (fun i (size, step) ->
      if i > 0 then print_char ',';
      let wire =
        "GET / HTTP/1.1\r\nHost: x\r\nX: " ^ String.make size 'a' ^ "\r\n\r\n"
      in
      let cfg = Result.get_ok (limits ~step ()) in
      let iterations = 1000 in
      Gc.full_major ();
      let before = Gc.allocated_bytes () and time = Mtime_clock.counter () in
      for _ = 1 to iterations do
        let d = head_decoder ~limits:cfg Request in
        let rec consume off =
          match feed_head d wire ~off ~len:(String.length wire - off) with
          | Ok (n, None) when n > 0 -> consume (off + n)
          | Ok (n, Some _) when off + n = String.length wire -> ()
          | _ -> failwith "benchmark input did not decode"
        in
        consume 0
      done;
      let elapsed = Mtime.Span.to_float_ns (Mtime_clock.count time) in
      let allocated = Gc.allocated_bytes () -. before in
      Printf.printf
        "{\"field_bytes\":%d,\"step\":%d,\"iterations\":%d,\"ns_per_head\":%.3f,\"allocated_bytes_per_head\":%.3f}"
        size step iterations
        (elapsed /. float iterations)
        (allocated /. float iterations))
    [ (16, 1); (256, 1); (4096, 1); (16, 16384); (256, 16384); (4096, 16384) ];
  print_endline "]}"
