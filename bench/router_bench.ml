open Http_kit_core
module R = Http_kit_router

let () =
  let results = ref [] in
  List.iter
    (fun size ->
      let table =
        Result.get_ok
          (R.compile
             (List.init size (fun n ->
                  let pattern =
                    Result.get_ok
                      (R.pattern ("/group" ^ string_of_int n ^ "/:id"))
                  in
                  R.route ~meth:Method.get pattern n)))
      in
      List.iter
        (fun (name, method_, path, expected) ->
          let target = Result.get_ok (Target.of_string path) in
          let lookup () =
            match (R.lookup table ~meth:method_ ~target, expected) with
            | Ok (R.Matched m), Some n -> assert (m.value = n)
            | Ok R.Not_found, None -> ()
            | Ok (R.Method_not_allowed [ m ]), None ->
                assert (Method.equal m Method.get)
            | _ -> failwith "invalid routing benchmark result"
          in
          let iterations = 1000 in
          Gc.full_major ();
          let before = Gc.allocated_bytes ()
          and timer = Mtime_clock.counter () in
          for _ = 1 to iterations do
            lookup ()
          done;
          let ns =
            Mtime.Span.to_float_ns (Mtime_clock.count timer) /. float iterations
          in
          let bytes = (Gc.allocated_bytes () -. before) /. float iterations in
          results :=
            Printf.sprintf
              "{\"routes\":%d,\"case\":%S,\"iterations\":%d,\"ns_per_lookup\":%.3f,\"allocated_bytes_per_lookup\":%.3f}"
              size name iterations ns bytes
            :: !results)
        [
          ("first", Method.get, "/group0/value", Some 0);
          ( "last",
            Method.get,
            "/group" ^ string_of_int (size - 1) ^ "/value",
            Some (size - 1) );
          ("missing", Method.get, "/missing/value", None);
          ("method", Method.post, "/group0/value", None);
        ])
    [ 10; 100; 1000 ];
  Printf.printf
    "{\"compiler\":%S,\"scope\":\"advisory routing \
     microbenchmarks\",\"results\":[%s]}\n"
    Sys.ocaml_version
    (String.concat "," (List.rev !results))
