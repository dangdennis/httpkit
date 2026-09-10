open Validation

type t = string

let of_string ?(max_length = 64) s =
  let* () = length ~component:Method ~max_length ~allow_empty:false s in
  let* () = bytes ~component:Method token s in
  Ok s

let to_string s = s
let equal = String.equal
let get = "GET"
let head = "HEAD"
let post = "POST"
let put = "PUT"
let delete = "DELETE"
let connect = "CONNECT"
let options = "OPTIONS"
let trace = "TRACE"
let patch = "PATCH"
