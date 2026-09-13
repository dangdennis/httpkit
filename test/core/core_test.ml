let () =
  List.iter
    (fun requirement ->
      if requirement.Harness.Registry.layer = "core-values" then
        List.iter
          (fun name ->
            if not (List.mem_assoc name Core_cases.cases) then
              failwith ("unknown core case: " ^ name))
          requirement.cases)
    Harness.Registry.requirements;
  Alcotest.run "httpkit-core"
    [
      ( "core",
        List.map
          (fun (name, f) -> Alcotest.test_case name `Quick f)
          (Core_cases.cases @ Core_cases.properties ~seed:42 ~count:1000) );
    ]
