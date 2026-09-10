let () =
  let cases = Self_cases.cases @ Self_cases.properties ~seed:42 ~count:200 in
  Alcotest.run "http-kit harness (synthetic subjects only)"
    [
      ( "self",
        List.map (fun (name, f) -> Alcotest.test_case name `Quick f) cases );
    ]
