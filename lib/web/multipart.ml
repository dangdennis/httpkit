open Httpkit_core

type part = { name : string; filename : string option; headers : Headers.t }
type event = Begin of part | Data of string | End
type phase = Initial | Headers | Body | Closing | Done | Failed

type t = {
  marker : string;
  max_header : int;
  max_parts : int;
  max_part : int;
  max_total : int;
  emit : event -> unit;
  mutable phase : phase;
  mutable pending : string;
  mutable parts : int;
  mutable part_bytes : int;
  mutable total : int;
}

exception Invalid of string

let invalid s = raise (Invalid s)

let quoted s =
  if String.length s >= 2 && s.[0] = '"' && s.[String.length s - 1] = '"' then (
    let v = String.sub s 1 (String.length s - 2) in
    if
      String.exists
        (fun c -> c = '"' || c = '\\' || Char.code c < 32 || Char.code c = 127)
        v
    then invalid "unsupported quoted parameter";
    v)
  else if
    s <> ""
    && String.for_all
         (function
           | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
           | _ -> false)
         s
  then s
  else invalid "invalid parameter"

let parameters raw =
  match String.split_on_char ';' raw with
  | [] -> invalid "missing media type"
  | kind :: rest ->
      let seen = Hashtbl.create 8 in
      let params =
        List.map
          (fun field ->
            match String.index_opt field '=' with
            | None -> invalid "parameter needs value"
            | Some i ->
                let k =
                  String.lowercase_ascii (String.trim (String.sub field 0 i))
                in
                if Hashtbl.mem seen k then invalid "duplicate parameter";
                Hashtbl.add seen k ();
                ( k,
                  quoted
                    (String.trim
                       (String.sub field (i + 1) (String.length field - i - 1)))
                ))
          rest
      in
      (String.lowercase_ascii (String.trim kind), params)

let valid_boundary b =
  String.length b >= 1
  && String.length b <= 70
  && String.for_all
       (function
         | 'a' .. 'z'
         | 'A' .. 'Z'
         | '0' .. '9'
         | '\'' | '(' | ')' | '+' | '_' | ',' | '-' | '.' | '/' | ':' | '='
         | '?' ->
             true
         | _ -> false)
       b

let boundary raw =
  try
    let kind, params = parameters raw in
    match (kind, List.assoc_opt "boundary" params) with
    | "multipart/form-data", Some b when valid_boundary b -> Ok b
    | _ -> Error "multipart boundary"
  with Invalid e -> Error e

let create ?(max_header_bytes = 8192) ?(max_parts = 100)
    ?(max_part_bytes = 1048576) ?(max_total_bytes = 8388608) ~boundary emit =
  if
    (not (valid_boundary boundary))
    || max_header_bytes < 0 || max_parts < 0 || max_part_bytes < 0
    || max_total_bytes < 0
  then invalid_arg "multipart limits";
  {
    marker = "\r\n--" ^ boundary;
    max_header = max_header_bytes;
    max_parts;
    max_part = max_part_bytes;
    max_total = max_total_bytes;
    emit;
    phase = Initial;
    pending = "";
    parts = 0;
    part_bytes = 0;
    total = 0;
  }

let locate needle haystack start =
  let rec loop i =
    if i + String.length needle > String.length haystack then None
    else if String.sub haystack i (String.length needle) = needle then Some i
    else loop (i + 1)
  in
  loop start

let drop t n = t.pending <- String.sub t.pending n (String.length t.pending - n)

let emit_data t n =
  if n > t.max_part - t.part_bytes then invalid "multipart part size";
  if n > 0 then (
    let data = String.sub t.pending 0 n in
    drop t n;
    t.part_bytes <- t.part_bytes + n;
    t.emit (Data data))

let parse_part raw =
  String.iteri
    (fun i c ->
      if
        (c = '\n' && (i = 0 || raw.[i - 1] <> '\r'))
        || (c = '\r' && (i + 1 = String.length raw || raw.[i + 1] <> '\n'))
      then invalid "part header line ending")
    raw;
  let lines = String.split_on_char '\n' raw in
  let fields =
    List.map
      (fun line ->
        let line =
          if String.ends_with ~suffix:"\r" line then
            String.sub line 0 (String.length line - 1)
          else line
        in
        match String.index_opt line ':' with
        | None -> invalid "part header"
        | Some i ->
            ( String.sub line 0 i,
              String.trim (String.sub line (i + 1) (String.length line - i - 1))
            ))
      lines
  in
  let headers =
    match Headers.of_list fields with
    | Ok h -> h
    | Error _ -> invalid "part headers"
  in
  if Reply.header_values "content-transfer-encoding" headers <> [] then
    invalid "part transfer encoding unsupported";
  match Reply.header_values "content-disposition" headers with
  | [ v ] -> (
      let kind, params = parameters v in
      match (kind, List.assoc_opt "name" params) with
      | "form-data", Some name when name <> "" ->
          { name; filename = List.assoc_opt "filename" params; headers }
      | _ -> invalid "part disposition")
  | _ -> invalid "part disposition required once"

let rec advance t =
  match t.phase with
  | Failed -> invalid "multipart failed"
  | Done -> if t.pending <> "" then invalid "multipart epilogue unsupported"
  | Closing ->
      if t.pending = "" || t.pending = "\r" then ()
      else if t.pending = "\r\n" then (
        t.pending <- "";
        t.phase <- Done)
      else invalid "multipart closing suffix"
  | Initial ->
      let initial = String.sub t.marker 2 (String.length t.marker - 2) in
      if String.length t.pending >= String.length initial + 2 then (
        if not (String.starts_with ~prefix:initial t.pending) then
          invalid "multipart initial boundary";
        drop t (String.length initial);
        if String.starts_with ~prefix:"--" t.pending then (
          drop t 2;
          t.phase <- Closing)
        else if String.starts_with ~prefix:"\r\n" t.pending then (
          drop t 2;
          t.phase <- Headers)
        else invalid "multipart boundary suffix";
        advance t)
  | Headers -> (
      match locate "\r\n\r\n" t.pending 0 with
      | None ->
          if String.length t.pending > t.max_header + 3 then
            invalid "multipart headers limit"
      | Some n ->
          if n > t.max_header || t.parts >= t.max_parts then
            invalid "multipart part limit";
          let part = parse_part (String.sub t.pending 0 n) in
          drop t (n + 4);
          t.parts <- t.parts + 1;
          t.part_bytes <- 0;
          t.phase <- Body;
          t.emit (Begin part);
          advance t)
  | Body ->
      let rec search start =
        match locate t.marker t.pending start with
        | None ->
            emit_data t
              (max 0 (String.length t.pending - String.length t.marker - 1))
        | Some i ->
            let suffix = i + String.length t.marker in
            if suffix + 2 > String.length t.pending then emit_data t i
            else
              let ending = String.sub t.pending suffix 2 in
              if ending <> "--" && ending <> "\r\n" then search (i + 1)
              else (
                emit_data t i;
                drop t (String.length t.marker + 2);
                t.emit End;
                t.phase <- (if ending = "--" then Closing else Headers);
                advance t)
      in
      search 0

let guarded t f =
  try
    f ();
    Ok ()
  with
  | Invalid e ->
      t.phase <- Failed;
      t.pending <- "";
      Error e
  | exn ->
      t.phase <- Failed;
      t.pending <- "";
      raise exn

let feed t chunk =
  guarded t (fun () ->
      if
        String.length chunk > 65536
        || String.length chunk > t.max_total - t.total
      then invalid "multipart input size";
      t.total <- t.total + String.length chunk;
      t.pending <- t.pending ^ chunk;
      advance t)

let finish t =
  guarded t (fun () ->
      advance t;
      match t.phase with
      | Done -> ()
      | Closing when t.pending = "" -> t.phase <- Done
      | _ -> invalid "truncated multipart")

let retained_bytes t = String.length t.pending
