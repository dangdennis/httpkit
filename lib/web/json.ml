type error = Too_large | Too_deep | Invalid_json | Duplicate_key

exception Rejected of error

let parse ?(max_bytes = 1048576) ?(max_depth = 64) s =
  if max_bytes < 0 || String.length s > max_bytes then Error Too_large
  else if max_depth < 0 then Error Too_deep
  else
    let depth = ref 0
    and quoted = ref false
    and escaped = ref false
    and overflow = ref false
    and non_json = ref false in
    String.iter
      (fun c ->
        if !quoted then (
          if Char.code c < 32 then non_json := true;
          if !escaped then escaped := false
          else if c = '\\' then escaped := true
          else if c = '"' then quoted := false)
        else
          match c with
          | '"' -> quoted := true
          | '[' | '{' ->
              incr depth;
              if !depth > max_depth then overflow := true
          | ']' | '}' -> decr depth
          | '/' | '(' | ')' | '<' | '>' | '\'' -> non_json := true
          | c
            when Char.code c < 32 && not (List.mem c [ ' '; '\t'; '\n'; '\r' ])
            ->
              non_json := true
          | _ -> ())
      s;
    if (not (String.is_valid_utf_8 s)) || !non_json then Error Invalid_json
    else if !overflow then Error Too_deep
    else
      try
        let value = Yojson.Safe.from_string s in
        let rec validate = function
          | `Assoc fields ->
              let seen = Hashtbl.create (List.length fields) in
              List.iter
                (fun (k, v) ->
                  if not (String.is_valid_utf_8 k) then
                    raise (Rejected Invalid_json);
                  if Hashtbl.mem seen k then raise (Rejected Duplicate_key);
                  Hashtbl.add seen k ();
                  validate v)
                fields
          | `List vs -> List.iter validate vs
          | `String v when not (String.is_valid_utf_8 v) ->
              raise (Rejected Invalid_json)
          | `Float v when not (Float.is_finite v) ->
              raise (Rejected Invalid_json)
          | _ -> ()
        in
        validate value;
        Ok value
      with
      | Yojson.Json_error _ -> Error Invalid_json
      | Rejected e -> Error e
