open Httpkit_core

type event =
  | Text of string
  | Binary of string
  | Ping of string
  | Pong of string
  | Close of int option * string

type t = {
  max_frame : int;
  max_message : int;
  mutable pending : string;
  message : Buffer.t;
  mutable opcode : int option;
  mutable closed : bool;
  mutable failed : bool;
}

exception Protocol of string

let fail s = raise (Protocol s)

let valid_code n =
  (n >= 1000 && n <= 1014 && not (List.mem n [ 1004; 1005; 1006 ]))
  || (n >= 3000 && n <= 4999)

let close_payload s =
  if s = "" then Close (None, "")
  else if String.length s = 1 then fail "short close"
  else
    let code = (Char.code s.[0] * 256) + Char.code s.[1] in
    let reason = String.sub s 2 (String.length s - 2) in
    if (not (valid_code code)) || not (String.is_valid_utf_8 reason) then
      fail "invalid close";
    Close (Some code, reason)

let server ?(max_frame = 1048576) ?(max_message = 4194304) () =
  if max_frame < 0 || max_message < 0 || max_frame > max_int - 65550 then
    invalid_arg "websocket limits";
  {
    max_frame;
    max_message;
    pending = "";
    message = Buffer.create 256;
    opcode = None;
    closed = false;
    failed = false;
  }

let frame_event t op fin payload =
  if op >= 8 then (
    if (not fin) || String.length payload > 125 then fail "fragmented control";
    match op with
    | 8 ->
        let event = close_payload payload in
        t.closed <- true;
        Buffer.clear t.message;
        t.opcode <- None;
        Some event
    | 9 -> Some (Ping payload)
    | 10 -> Some (Pong payload)
    | _ -> fail "control opcode")
  else
    let opcode =
      match (op, t.opcode) with
      | (1 | 2), None -> op
      | 0, Some original -> original
      | _ -> fail "fragment sequence"
    in
    if String.length payload > t.max_message - Buffer.length t.message then
      fail "message limit";
    Buffer.add_string t.message payload;
    if fin then (
      let data = Buffer.contents t.message in
      Buffer.clear t.message;
      t.opcode <- None;
      if opcode = 1 then (
        if not (String.is_valid_utf_8 data) then fail "text UTF-8";
        Some (Text data))
      else Some (Binary data))
    else (
      t.opcode <- Some opcode;
      None)

let feed t chunk =
  if t.failed then Error "websocket failed"
  else
    try
      if String.length chunk > 65536 then fail "input chunk limit";
      if t.closed && chunk <> "" then fail "data after close";
      t.pending <- t.pending ^ chunk;
      let rec parse acc =
        let s = t.pending in
        if t.closed && s <> "" then fail "data after close"
        else if String.length s < 2 then List.rev acc
        else
          let a = Char.code s.[0] and b = Char.code s.[1] in
          let fin = a land 128 <> 0 and op = a land 15 and small = b land 127 in
          if
            a land 112 <> 0
            || b land 128 = 0
            || not (List.mem op [ 0; 1; 2; 8; 9; 10 ])
          then fail "frame flags";
          let ext = if small = 126 then 2 else if small = 127 then 8 else 0 in
          if String.length s < 2 + ext then List.rev acc
          else
            let length = ref (Int64.of_int (if ext = 0 then small else 0)) in
            for i = 0 to ext - 1 do
              length :=
                Int64.logor
                  (Int64.shift_left !length 8)
                  (Int64.of_int (Char.code s.[2 + i]))
            done;
            if
              !length < 0L
              || !length > Int64.of_int t.max_frame
              || (ext = 2 && !length < 126L)
              || (ext = 8 && !length < 65536L)
            then fail "frame length";
            if op >= 8 && ((not fin) || !length > 125L) then
              fail "control length";
            let n = Int64.to_int !length and start = 2 + ext + 4 in
            if String.length s < start + n then List.rev acc
            else
              let payload =
                String.init n (fun i ->
                    Char.chr
                      (Char.code s.[start + i]
                      lxor Char.code s.[2 + ext + (i mod 4)]))
              in
              t.pending <- String.sub s (start + n) (String.length s - start - n);
              let event = frame_event t op fin payload in
              parse (match event with None -> acc | Some e -> e :: acc)
      in
      Ok (parse [])
    with Protocol e ->
      t.failed <- true;
      t.pending <- "";
      Buffer.clear t.message;
      Error e

let eof t =
  if t.failed then Error "websocket failed"
  else if t.closed && t.pending = "" then Ok ()
  else (
    t.failed <- true;
    t.pending <- "";
    Buffer.clear t.message;
    Error "abnormal websocket EOF")

let encode event =
  try
    let op, payload =
      match event with
      | Text s ->
          if not (String.is_valid_utf_8 s) then fail "text UTF-8";
          (1, s)
      | Binary s -> (2, s)
      | Ping s -> (9, s)
      | Pong s -> (10, s)
      | Close (None, "") -> (8, "")
      | Close (Some n, reason) when valid_code n && String.is_valid_utf_8 reason
        ->
          ( 8,
            String.init 2 (function
              | 0 -> Char.chr (n lsr 8)
              | _ -> Char.chr (n land 255))
            ^ reason )
      | Close _ -> fail "invalid close"
    in
    let n = String.length payload in
    if op >= 8 && n > 125 then fail "control length";
    let b = Buffer.create (n + 10) in
    Buffer.add_char b (Char.chr (128 lor op));
    if n < 126 then Buffer.add_char b (Char.chr n)
    else if n <= 65535 then (
      Buffer.add_char b (Char.chr 126);
      Buffer.add_char b (Char.chr (n lsr 8));
      Buffer.add_char b (Char.chr (n land 255)))
    else (
      Buffer.add_char b (Char.chr 127);
      for i = 7 downto 0 do
        Buffer.add_char b
          (Char.chr
             (Int64.to_int
                (Int64.logand
                   (Int64.shift_right_logical (Int64.of_int n) (i * 8))
                   255L)))
      done);
    Buffer.add_string b payload;
    Ok (Buffer.contents b)
  with Protocol e -> Error e

let handshake ~allowed_origins request =
  let h = Request.headers request in
  let one name =
    match Reply.header_values name h with [ v ] -> Some v | _ -> None
  in
  let token name expected =
    Reply.header_values name h
    |> List.concat_map (String.split_on_char ',')
    |> List.exists (fun s -> String.lowercase_ascii (String.trim s) = expected)
  in
  if
    Request.meth request <> Method.get
    || Request.version request <> Version.Http_1_1
    || one "sec-websocket-version" <> Some "13"
    || (not (token "connection" "upgrade"))
    || Option.map String.lowercase_ascii (one "upgrade") <> Some "websocket"
  then Error "invalid websocket handshake"
  else
    match (one "origin", one "sec-websocket-key") with
    | Some origin, Some key
      when origin <> "null" && List.mem origin allowed_origins -> (
        match Base64.decode key with
        | Ok decoded
          when String.length decoded = 16 && Base64.encode_string decoded = key
          ->
            let accept =
              Digestif.SHA1.(
                to_raw_string
                  (digest_string (key ^ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
              |> Base64.encode_string
            in
            let headers =
              Result.get_ok
                (Headers.of_list
                   [
                     ("upgrade", "websocket");
                     ("connection", "Upgrade");
                     ("sec-websocket-accept", accept);
                   ])
            in
            Ok
              (Response.create
                 ~status:(Result.get_ok (Status.of_int 101))
                 ~headers ())
        | _ -> Error "invalid websocket key")
    | _ -> Error "websocket origin denied"
