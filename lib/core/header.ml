open Validation

module Name = struct
  type t = string

  let of_string ?(max_length = 256) s =
    let* () = length ~component:Header_name ~max_length ~allow_empty:false s in
    let* () = bytes ~component:Header_name token s in
    Ok (String.lowercase_ascii s)

  let to_string s = s
  let equal = String.equal
end

module Value = struct
  type t = string

  let of_string ?(max_length = 8192) s =
    let* () = length ~component:Header_value ~max_length ~allow_empty:true s in
    let* () =
      bytes ~component:Header_value
        (fun c -> c = '\t' || (Char.code c >= 32 && Char.code c <> 127))
        s
    in
    let ows c = c = ' ' || c = '\t' in
    if s <> "" && ows s.[0] then
      error ~offset:0 Header_value Surrounding_whitespace
    else if s <> "" && ows s.[String.length s - 1] then
      error ~offset:(String.length s - 1) Header_value Surrounding_whitespace
    else Ok s

  let to_string s = s
  let equal = String.equal
end

type t = { name : Name.t; value : Value.t }

let create name value = { name; value }

let of_strings name value =
  let* name = Name.of_string name in
  let* value = Value.of_string value in
  Ok (create name value)

let name t = t.name
let value t = t.value
