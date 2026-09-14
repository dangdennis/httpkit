let bounded run bytes = if String.length bytes <= 1024 then run bytes

let () =
  let selected = Sys.getenv_opt "HTTP_KIT_FUZZ_CASE" in
  if not (List.mem selected [ None; Some "server"; Some "client" ]) then
    invalid_arg "unknown fuzz case";
  List.iter
    (fun (name, run) ->
      if selected = None || selected = Some name then
        Fuzz_input.add ~name (bounded run))
    [
      ("server", Engine_scenarios.run);
      ("client", Engine_scenarios.client_fragments);
    ]
