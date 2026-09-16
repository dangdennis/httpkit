module M = Engine_scenarios
module S = Segmentation_support

let () =
  Alcotest.run "Hostile client sequencing"
    [
      ( "sequence",
        List.map
          (fun (case : M.sequence_case) ->
            Alcotest.test_case case.name `Quick (fun () ->
                let wire = M.sequence_input case in
                S.matrix case.name wire
                  (fun ~step cuts ->
                    for ack = 0 to 3 do
                      M.client_sequence case ~step ~ack
                        ~window:(S.window cuts (String.length wire))
                    done)
                  ()))
          M.sequence_cases );
    ]
