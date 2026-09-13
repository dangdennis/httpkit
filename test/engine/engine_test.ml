let () =
  List.iter
    (fun r ->
      if r.Harness.Registry.layer = "engine" then
        List.iter
          (fun n ->
            if not (List.mem_assoc n Engine_cases.cases) then
              failwith ("unlinked engine case: " ^ n))
          r.cases)
    Harness.Registry.requirements;

  Alcotest.run "httpkit-engine"
    [
      ( "engine",
        List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          (Engine_cases.cases @ Engine_cases.properties ~seed:42 ~count:1000) );
    ]
