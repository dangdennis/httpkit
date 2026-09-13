let bearer headers =
  match Reply.header_values "authorization" headers with
  | [] -> Ok None
  | [ s ] -> (
      match String.index_opt s ' ' with
      | Some i when String.lowercase_ascii (String.sub s 0 i) = "bearer" ->
          let token = String.sub s (i + 1) (String.length s - i - 1) in
          if
            token <> ""
            && String.length token <= 4096
            && String.for_all
                 (function
                   | 'a' .. 'z'
                   | 'A' .. 'Z'
                   | '0' .. '9'
                   | '-' | '.' | '_' | '~' | '+' | '/' | '=' ->
                       true
                   | _ -> false)
                 token
          then Ok (Some token)
          else Error "invalid bearer"
      | _ -> Error "unsupported authorization")
  | _ -> Error "duplicate authorization"

let authenticate ~verify headers =
  match bearer headers with
  | Error e -> Error e
  | Ok None -> Ok None
  | Ok (Some token) -> Ok (verify token)

let csrf ~allowed_origins ~token_valid ~meth headers =
  if List.mem (Httpkit_core.Method.to_string meth) [ "GET"; "HEAD"; "OPTIONS" ]
  then true
  else
    match
      ( Reply.header_values "origin" headers,
        Reply.header_values "x-csrf-token" headers )
    with
    | [ origin ], [ token ] ->
        origin <> "null"
        && List.mem origin allowed_origins
        && String.length token <= 256
        && token_valid token
    | _ -> false
