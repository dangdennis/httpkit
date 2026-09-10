open Validation

type t = string

let hex = function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false

let uri_byte = function
  | 'A' .. 'Z'
  | 'a' .. 'z'
  | '0' .. '9'
  | '-' | '.' | '_' | '~' | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ','
  | ';' | '=' | ':' | '/' | '?' | '[' | ']' | '@' ->
      true
  | _ -> false

let of_string ?(max_length = 8192) s =
  let* () = length ~component:Target ~max_length ~allow_empty:false s in
  let rec loop i =
    if i = String.length s then Ok s
    else if s.[i] = '%' then
      (* Check remaining length first so incomplete escapes cannot read past input. *)
      if String.length s - i < 3 || not (hex s.[i + 1] && hex s.[i + 2]) then
        error ~offset:i Target Invalid_escape
      else loop (i + 3)
    else if uri_byte s.[i] then loop (i + 1)
    else error ~offset:i Target Invalid_byte
  in
  loop 0

let to_string s = s
let equal = String.equal
