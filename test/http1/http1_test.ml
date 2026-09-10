let () =
  List.iter
    (fun r ->
      if r.Harness.Registry.layer = "http1" then
        List.iter
          (fun n ->
            if not (List.mem_assoc n Http1_cases.cases) then
              failwith ("unlinked HTTP/1 case: " ^ n))
          r.cases)
    Harness.Registry.requirements;

  Alcotest.run "http-kit-http1"
    [
      ( "http1",
        List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          (Http1_cases.cases @ Http1_cases.properties ~seed:42 ~count:1000) );
    ]
