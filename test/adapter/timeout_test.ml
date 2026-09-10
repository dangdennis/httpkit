module T = Http_kit_engine.Timeout

let remaining expected now t =
  Alcotest.(check (option (float 0.00001)))
    "deadline" expected (T.remaining ~now t)

let () =
  Alcotest.run "deadline policy"
    [
      ( "pure",
        [
          Alcotest.test_case "absolute header and shutdown deadlines" `Quick
            (fun () ->
              List.iter
                (fun phase ->
                  let t =
                    T.observe T.default ~now:2. ~phase:(Some phase) T.empty
                  in
                  let t =
                    T.progress T.default ~now:9. t
                    |> T.observe T.default ~now:10. ~phase:(Some phase)
                  in
                  remaining (Some 0.) 12. t;
                  remaining (Some (-1.)) 13. t)
                [ T.Head; T.Shutdown ]);
          Alcotest.test_case "idle progress and application backpressure" `Quick
            (fun () ->
              let t =
                T.observe T.default ~now:2. ~phase:(Some T.Body) T.empty
                |> T.progress T.default ~now:20.
              in
              remaining (Some 30.) 20. t;
              let t = T.observe T.default ~now:21. ~phase:None t in
              remaining None 100. t;
              remaining (Some 30.) 100.
                (T.observe T.default ~now:100. ~phase:(Some T.Body) t));
          Alcotest.test_case "reject invalid durations" `Quick (fun () ->
              List.iter
                (fun n ->
                  assert (Result.is_error (T.policy ~header:n ()));
                  assert (Result.is_error (T.policy ~body_idle:(Some n) ())))
                [ 0.; -1.; nan; infinity; neg_infinity ];
              let p =
                Result.get_ok (T.policy ~body_idle:None ~write_idle:None ())
              in
              remaining None 100.
                (T.observe p ~now:0. ~phase:(Some T.Body) T.empty));
        ] );
    ]
