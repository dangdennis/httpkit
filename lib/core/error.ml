type component =
  | Method
  | Header_name
  | Header_value
  | Headers
  | Target
  | Status

type reason =
  | Empty
  | Invalid_byte
  | Invalid_escape
  | Surrounding_whitespace
  | Too_long
  | Too_many_fields
  | Invalid_limit
  | Out_of_range

type t = { component : component; reason : reason; offset : int option }

let to_string { component; reason; offset } =
  let component =
    match component with
    | Method -> "method"
    | Header_name -> "header name"
    | Header_value -> "header value"
    | Headers -> "headers"
    | Target -> "target"
    | Status -> "status"
  in
  let reason =
    match reason with
    | Empty -> "empty"
    | Invalid_byte -> "invalid byte"
    | Invalid_escape -> "invalid escape"
    | Surrounding_whitespace -> "surrounding whitespace"
    | Too_long -> "too long"
    | Too_many_fields -> "too many fields"
    | Invalid_limit -> "invalid limit"
    | Out_of_range -> "out of range"
  in
  match offset with
  | None -> component ^ ": " ^ reason
  | Some n -> Printf.sprintf "%s: %s at byte %d" component reason n
