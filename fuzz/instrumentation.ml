(* File-per-execution target: validate OCaml's actual AFL coverage plumbing. *)
let () =
  let input =
    if Array.length Sys.argv = 2 then Sys.argv.(1)
    else failwith "input path required"
  in
  let ic = open_in_bin input in
  let c =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> try input_char ic with End_of_file -> '\000')
  in
  if c = 'A' then print_endline "branch-a"
  else if c = 'B' then print_endline "branch-b"
  else print_endline "branch-other";
  if Sys.getenv_opt "HTTP_KIT_PLANTED_FAULT" = Some "1" && c = '!' then
    failwith "deliberately planted instrumentation fault"
