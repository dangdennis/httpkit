let max_connections = function
  | None -> 16
  | Some value ->
      let invalid () =
        invalid_arg "HTTPKIT_MAX_CONNECTIONS must be an integer in 1..1024"
      in
      if
        value = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') value)
      then invalid ();
      let count = try int_of_string value with Failure _ -> invalid () in
      if count < 1 || count > 1024 then invalid ();
      count
