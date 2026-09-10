open Harness

let () =
  Crowbar.add_test ~name:"bounded scenario decoder" [ Crowbar.bytes ]
    (fun bytes ->
      if
        Sys.getenv_opt "HTTP_KIT_CROWBAR_PLANTED_FAULT" = Some "1"
        && String.contains bytes '!'
      then Crowbar.check false;
      match Scenario.of_string bytes with
      | Error _ -> ()
      | Ok s ->
          Crowbar.check (Scenario.validate s = Ok ());
          Crowbar.check
            (Scenario.of_string (Yojson.Safe.to_string (Scenario.to_json s))
            = Ok s));
  Crowbar.add_test ~name:"synthetic lifecycle/model agreement" [ Crowbar.bytes ]
    (fun bytes ->
      let open Scenario in
      let actions =
        Open 0
        :: Begin (0, 1, 10000)
        :: List.init
             (min 128 (String.length bytes))
             (fun i ->
               match Char.code bytes.[i] mod 8 with
               | 0 -> Input (0, String.make 1 bytes.[i])
               | 1 -> Consume (0, 1)
               | 2 -> Send (0, i, "x")
               | 3 -> Write (0, 1)
               | 4 -> Wait_body 0
               | 5 -> Advance 1L
               | 6 -> Cancel 0
               | _ -> Finish 0)
      in
      let s = Fixtures.scenario "FUZZ.MODEL" actions in
      Crowbar.check ((Runner.run Contract.Correct s).failure = None))
