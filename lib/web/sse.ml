let single s =
  String.is_valid_utf_8 s
  && not (String.exists (fun c -> c = '\r' || c = '\n' || c = '\000') s)

let event ?id ?event ?retry ?(max_bytes = 65536) data =
  if not (String.is_valid_utf_8 data) then Error "SSE UTF-8"
  else if max_bytes < 0 || String.length data > max_bytes then Error "SSE size"
  else if
    List.exists
      (fun s -> (not (single s)) || String.length s > 1024)
      (List.filter_map Fun.id [ id; event ])
  then Error "SSE field"
  else
    match retry with
    | Some n when n < 0 -> Error "SSE retry"
    | _ ->
        let b = Buffer.create (String.length data) in
        let rec normalize i =
          if i < String.length data then
            if data.[i] = '\r' then (
              Buffer.add_char b '\n';
              normalize
                (if i + 1 < String.length data && data.[i + 1] = '\n' then i + 2
                 else i + 1))
            else (
              Buffer.add_char b data.[i];
              normalize (i + 1))
        in
        normalize 0;
        let normalized = Buffer.contents b in
        let fields =
          (match id with None -> [] | Some v -> [ "id: " ^ v ])
          @ (match event with None -> [] | Some v -> [ "event: " ^ v ])
          @
          match retry with
          | None -> []
          | Some v -> [ "retry: " ^ string_of_int v ]
        in
        Ok
          (String.concat "\n"
             (fields
             @ List.map
                 (fun s -> "data: " ^ s)
                 (String.split_on_char '\n' normalized))
          ^ "\n\n")

let comment s =
  if single s && String.length s <= 1024 then Ok (": " ^ s ^ "\n\n")
  else Error "SSE comment"
