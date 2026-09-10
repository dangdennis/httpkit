let bounded run bytes = if String.length bytes <= 1024 then run bytes

let () =
  Crowbar.add_test ~name:"server lifecycle and output prefix model"
    [ Crowbar.bytes ]
    (bounded Engine_scenarios.run);
  Crowbar.add_test ~name:"client fragmented response lifecycle"
    [ Crowbar.bytes ]
    (bounded Engine_scenarios.client_fragments)
