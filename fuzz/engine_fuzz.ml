let () =
  let selected = Sys.getenv_opt "HTTP_KIT_FUZZ_CASE" in
  if not (List.mem selected [ None; Some "server"; Some "client" ]) then
    invalid_arg "unknown fuzz case";
  List.iter
    (fun (name, run) ->
      if selected = None || selected = Some name then
        Fuzz_input.add ~max_length:1024 ~name run)
    [
      ("server", Engine_scenarios.run);
      ( "client",
        fun bytes ->
          Engine_scenarios.client_fragments bytes;
          Engine_scenarios.client_sequences bytes );
    ]
