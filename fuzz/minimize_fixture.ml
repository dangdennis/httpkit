let contains input needle =
  let rec loop i =
    i + String.length needle <= String.length input
    && (String.sub input i (String.length needle) = needle || loop (i + 1))
  in
  loop 0

let () =
  Fuzz_input.add ~name:"minimization fixture" (fun input ->
      if input = "TIMEOUT" then Unix.sleepf 10.;
      if input = "EXIT" then exit 7;
      if contains input "BUG" then failwith "expected property failure";
      if contains input "ALT" then failwith "different failure site")
