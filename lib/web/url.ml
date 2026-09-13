type error = Invalid_escape | Invalid_byte | Limit | Duplicate

let hex = function
  | '0' .. '9' as c -> Char.code c - 48
  | 'a' .. 'f' as c -> Char.code c - 87
  | 'A' .. 'F' as c -> Char.code c - 55
  | _ -> -1

let decode ?(plus = false) ?(allow_newlines = false) ?(max_bytes = 8192) s =
  if max_bytes < 0 || String.length s > max_bytes then Error Limit
  else
    let b = Buffer.create (String.length s) in
    let rec loop i =
      if i = String.length s then Ok (Buffer.contents b)
      else
        let next c n =
          if
            Char.code c < 32
            && not (allow_newlines && List.mem c [ '\r'; '\n'; '\t' ])
            || Char.code c = 127
          then Error Invalid_byte
          else (
            Buffer.add_char b c;
            loop n)
        in
        match s.[i] with
        | '%' when i + 2 < String.length s ->
            let a = hex s.[i + 1] and c = hex s.[i + 2] in
            if a < 0 || c < 0 then Error Invalid_escape
            else next (Char.chr ((a * 16) + c)) (i + 3)
        | '%' -> Error Invalid_escape
        | '+' when plus -> next ' ' (i + 1)
        | c -> next c (i + 1)
    in
    loop 0

let encode s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~') as c ->
          Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let split_once c s =
  match String.index_opt s c with
  | None -> (s, "")
  | Some i -> (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))

let pairs ?(max_bytes = 8192) ?(max_fields = 100) s =
  if max_bytes < 0 || max_fields < 0 || String.length s > max_bytes then
    Error Limit
  else if s = "" then Ok []
  else
    let rec loop count acc start i =
      if i = String.length s || s.[i] = '&' then
        if count >= max_fields then Error Limit
        else
          let key, value = split_once '=' (String.sub s start (i - start)) in
          match
            ( decode ~plus:true ~max_bytes key,
              decode ~plus:true ~allow_newlines:true ~max_bytes value )
          with
          | Ok key, Ok value ->
              let acc = (key, value) :: acc in
              if i = String.length s then Ok (List.rev acc)
              else loop (count + 1) acc (i + 1) (i + 1)
          | Error e, _ | _, Error e -> Error e
      else loop count acc start (i + 1)
    in
    loop 0 [] 0 0

let query ?max_bytes ?max_fields target =
  let _, q = split_once '?' target in
  pairs ?max_bytes ?max_fields q

let unique name pairs =
  match
    List.filter_map (fun (k, v) -> if k = name then Some v else None) pairs
  with
  | [] -> Ok None
  | [ v ] -> Ok (Some v)
  | _ -> Error Duplicate

let path_segments ?(max_bytes = 8192) path =
  if max_bytes < 0 || String.length path > max_bytes then Error Limit
  else if
    path = ""
    || path.[0] <> '/'
    || String.contains path '?' || String.contains path '#'
  then Error Invalid_byte
  else
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | raw :: rest -> (
          match decode ~max_bytes raw with
          | Error e -> Error e
          | Ok s
            when s = "." || s = ".." || String.contains s '/'
                 || String.contains s '\\' ->
              Error Invalid_byte
          | Ok s -> loop (s :: acc) rest)
    in
    loop [] (List.tl (String.split_on_char '/' path))
