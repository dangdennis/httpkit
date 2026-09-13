type same_site = Strict | Lax | None_

let token s =
  match Httpkit_core.Header.Name.of_string s with
  | Ok _ -> true
  | Error _ -> false

let octet c =
  let n = Char.code c in
  n = 0x21
  || (n >= 0x23 && n <= 0x2b)
  || (n >= 0x2d && n <= 0x3a)
  || (n >= 0x3c && n <= 0x5b)
  || (n >= 0x5d && n <= 0x7e)

let value s = String.for_all octet s

let parse ?(max_bytes = 8192) ?(max_cookies = 100) fields =
  let rec size n = function
    | [] -> true
    | h :: t -> String.length h <= max_bytes - n && size (n + String.length h) t
  in
  if max_bytes < 0 || max_cookies < 0 || not (size 0 fields) then
    Error "cookie limit"
  else
    let rec loop count acc = function
      | [] -> Ok (List.rev acc)
      | s :: rest -> (
          if count >= max_cookies then Error "cookie count"
          else
            let s = String.trim s in
            match String.index_opt s '=' with
            | None -> Error "invalid cookie"
            | Some i ->
                let k = String.sub s 0 i
                and v = String.sub s (i + 1) (String.length s - i - 1) in
                let v =
                  if
                    String.length v >= 2
                    && v.[0] = '"'
                    && v.[String.length v - 1] = '"'
                  then String.sub v 1 (String.length v - 2)
                  else v
                in
                if not (token k && value v) then Error "invalid cookie"
                else loop (count + 1) ((k, v) :: acc) rest)
    in
    loop 0 [] (List.concat_map (String.split_on_char ';') fields)

let find k fields =
  match
    List.filter_map (fun (n, v) -> if n = k then Some v else None) fields
  with
  | [] -> Ok None
  | [ v ] -> Ok (Some v)
  | _ -> Error "duplicate cookie"

let set ?(secure = true) ?(http_only = true) ?(same_site = Lax) ?(path = "/")
    ?max_age name v =
  if not (token name && value v) then invalid_arg "invalid cookie";
  if
    path = ""
    || path.[0] <> '/'
    || String.exists
         (fun c -> Char.code c < 32 || Char.code c >= 127 || c = ';')
         path
  then invalid_arg "cookie path";
  if
    (same_site = None_
    || String.starts_with ~prefix:"__Secure-" name
    || String.starts_with ~prefix:"__Host-" name)
    && not secure
  then invalid_arg "cookie requires Secure";
  if String.starts_with ~prefix:"__Host-" name && path <> "/" then
    invalid_arg "Host cookie path";
  String.concat "; "
    ([ name ^ "=" ^ v; "Path=" ^ path ]
    @ (if secure then [ "Secure" ] else [])
    @ (if http_only then [ "HttpOnly" ] else [])
    @ [
        ("SameSite="
        ^
        match same_site with
        | Strict -> "Strict"
        | Lax -> "Lax"
        | None_ -> "None");
      ]
    @
    match max_age with
    | None -> []
    | Some n when n >= 0 -> [ "Max-Age=" ^ string_of_int n ]
    | _ -> invalid_arg "cookie max-age")
