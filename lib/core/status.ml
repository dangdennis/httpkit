type t = int

let of_int n =
  if n < 100 || n > 599 then Validation.error Status Out_of_range else Ok n

let to_int n = n
let equal = Int.equal
let continue = 100
let ok = 200
let no_content = 204
let not_modified = 304
let bad_request = 400
let not_found = 404
let internal_server_error = 500
