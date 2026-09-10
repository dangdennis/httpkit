let error ?offset component reason = Error Error.{ component; reason; offset }

let token = function
  | 'A' .. 'Z'
  | 'a' .. 'z'
  | '0' .. '9'
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_' | '`'
  | '|' | '~' ->
      true
  | _ -> false

let length ~component ~max_length ~allow_empty s =
  if max_length < 0 then error component Invalid_limit
  else if String.length s > max_length then error component Too_long
  else if s = "" && not allow_empty then error component Empty
  else Ok ()

let bytes ~component predicate s =
  let rec loop i =
    if i = String.length s then Ok ()
    else if predicate s.[i] then loop (i + 1)
    else error ~offset:i component Invalid_byte
  in
  loop 0

let ( let* ) = Result.bind
