open Http_kit_core

type error =
  | Invalid_slice
  | Invalid_state
  | Invalid_line
  | Invalid_field
  | Unsupported_version
  | Invalid_target
  | Invalid_host
  | Ambiguous_framing
  | Invalid_length
  | Unsupported_coding
  | Unsupported_expectation
  | Invalid_chunk
  | Invalid_trailer
  | Limit_exceeded
  | Unexpected_eof

let error_to_string = function
  | Invalid_slice -> "invalid slice"
  | Invalid_state -> "invalid state"
  | Invalid_line -> "invalid line"
  | Invalid_field -> "invalid field"
  | Unsupported_version -> "unsupported HTTP version"
  | Invalid_target -> "invalid target"
  | Invalid_host -> "invalid Host/authority"
  | Ambiguous_framing -> "ambiguous framing"
  | Invalid_length -> "invalid content length"
  | Unsupported_coding -> "unsupported transfer coding"
  | Unsupported_expectation -> "unsupported expectation"
  | Invalid_chunk -> "invalid chunk"
  | Invalid_trailer -> "invalid trailer"
  | Limit_exceeded -> "resource limit exceeded"
  | Unexpected_eof -> "unexpected EOF"

let ( let* ) = Result.bind
let core error = function Ok x -> Ok x | Error _ -> Error error

type limits = {
  line : int;
  headers : int;
  fields : int;
  trailers : int;
  trailer_fields : int;
  chunk_line : int;
  step : int;
  body : int64 option;
}

let limits ?(line = 8192) ?(headers = 32768) ?(fields = 100) ?(trailers = 16384)
    ?(trailer_fields = 64) ?(chunk_line = 1024) ?(step = 16384) ?body () =
  if
    line < 2 || headers < 4 || fields < 0 || trailers < 2 || trailer_fields < 0
    || chunk_line < 3 || step < 1
    || Option.fold ~none:false ~some:(fun n -> n < 0L) body
  then Error Limit_exceeded
  else
    Ok
      {
        line;
        headers;
        fields;
        trailers;
        trailer_fields;
        chunk_line;
        step;
        body;
      }

let default_limits = Result.get_ok (limits ())
let step_limit limits = limits.step

let slice s off len =
  off >= 0 && len >= 0 && off <= String.length s && len <= String.length s - off

let trim s =
  let ows c = c = ' ' || c = '\t' in
  let a = ref 0 and b = ref (String.length s) in
  while !a < !b && ows s.[!a] do
    incr a
  done;
  while !b > !a && ows s.[!b - 1] do
    decr b
  done;
  String.sub s !a (!b - !a)

let name s = Result.get_ok (Header.Name.of_string s)

let values key hs =
  List.map Header.Value.to_string (Headers.get_all (name key) hs)

let tokens xs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | x :: rest ->
        let* n = core Invalid_field (Header.Name.of_string (trim x)) in
        loop (n :: acc) rest
  in
  loop [] (List.concat_map (String.split_on_char ',') xs)

let decimal s =
  if s = "" then Error Invalid_length
  else
    let rec loop i n =
      if i = String.length s then Ok n
      else
        let c = s.[i] in
        if c < '0' || c > '9' then Error Invalid_length
        else
          let digit = Int64.of_int (Char.code c - 48) in
          if n > Int64.div (Int64.sub Int64.max_int digit) 10L then
            Error Invalid_length
          else loop (i + 1) (Int64.add (Int64.mul n 10L) digit)
    in
    loop 0 0L

let forbidden n =
  List.mem (Header.Name.to_string n)
    [
      "host";
      "content-length";
      "transfer-encoding";
      "connection";
      "trailer";
      "te";
      "upgrade";
      "expect";
      "authorization";
      "proxy-authorization";
      "proxy-authenticate";
      "www-authenticate";
      "cookie";
      "set-cookie";
      "content-type";
      "content-encoding";
      "content-range";
      "range";
      "cache-control";
      "max-forwards";
    ]

(* Authority parsing is deliberately independent of DNS. IPv6 validation uses
   ipaddr's pure parser; interpreting arbitrary colon strings as hosts is unsafe. *)
let authority ?default_port ?(require_port = false) s =
  let port s =
    let* n = core Invalid_host (decimal s) in
    if n > 65535L then Error Invalid_host else Ok (Int64.to_int n)
  in
  let* host, suffix =
    if s = "" then Error Invalid_host
    else if s.[0] = '[' then
      match String.index_opt s ']' with
      | None -> Error Invalid_host
      | Some i ->
          let* ip =
            core Invalid_host (Ipaddr.V6.of_string (String.sub s 1 (i - 1)))
          in
          Ok
            ( "[" ^ Ipaddr.V6.to_string ip ^ "]",
              String.sub s (i + 1) (String.length s - i - 1) )
    else
      let i =
        Option.value (String.index_opt s ':') ~default:(String.length s)
      in
      let host = String.sub s 0 i in
      if
        host = ""
        || (not
              (String.for_all
                 (function
                   | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' -> true
                   | _ -> false)
                 host))
        || List.exists
             (fun label ->
               label = ""
               || label.[0] = '-'
               || label.[String.length label - 1] = '-')
             (String.split_on_char '.' host)
      then Error Invalid_host
      else Ok (String.lowercase_ascii host, String.sub s i (String.length s - i))
  in
  if suffix = "" then
    if require_port then Error Invalid_host else Ok (host, default_port)
  else if suffix.[0] <> ':' then Error Invalid_host
  else
    let* p = port (String.sub suffix 1 (String.length suffix - 1)) in
    Ok (host, Some p)

let validate_target meth target host =
  let target = Target.to_string target in
  if Method.equal meth Method.connect then
    let* a = authority ~require_port:true target in
    let* b = authority ~require_port:true host in
    if a = b then Ok () else Error Invalid_host
  else if target = "*" then
    if Method.equal meth Method.options then
      core Invalid_host (authority host) |> Result.map (fun _ -> ())
    else Error Invalid_target
  else if target.[0] = '/' then
    let* _ = authority host in
    if String.contains target '[' || String.contains target ']' then
      Error Invalid_target
    else Ok ()
  else
    let scheme, start =
      if String.starts_with ~prefix:"http://" target then (Some 80, 7)
      else if String.starts_with ~prefix:"https://" target then (Some 443, 8)
      else (None, 0)
    in
    match scheme with
    | None -> Error Invalid_target
    | Some port ->
        let rec finish i =
          if i = String.length target || target.[i] = '/' || target.[i] = '?'
          then i
          else finish (i + 1)
        in
        let stop = finish start in
        let* a =
          authority ~default_port:port (String.sub target start (stop - start))
        in
        let* b = authority ~default_port:port host in
        let path = String.sub target stop (String.length target - stop) in
        if String.contains path '[' || String.contains path ']' then
          Error Invalid_target
        else if a = b then Ok ()
        else Error Invalid_host

type framing = Empty | Fixed of int64 | Chunked | Close_delimited | Tunnel
type head = Request_head of unit Request.t | Response_head of unit Response.t

type metadata = {
  head : head;
  framing : framing;
  persistent : bool;
  expect_continue : bool;
  trailer_names : Header.Name.t list;
}

type role = Request | Response of Method.t

let headers = function
  | Request_head r -> Request.headers r
  | Response_head r -> Response.headers r

let validate cfg role head =
  let hs = headers head in
  let version =
    match head with
    | Request_head r -> Request.version r
    | Response_head r -> Response.version r
  in
  if version <> Version.Http_1_1 then Error Unsupported_version
  else
    let* () =
      match head with
      | Response_head _ -> Ok ()
      | Request_head r -> (
          match values "host" hs with
          | [ host ] -> validate_target (Request.meth r) (Request.target r) host
          | _ -> Error Invalid_host)
    in
    let cl = values "content-length" hs
    and te = values "transfer-encoding" hs in
    let* length =
      match cl with
      | [] -> Ok None
      | [ s ] ->
          let* n = decimal s in
          Ok (Some n)
      | _ -> Error Ambiguous_framing
    in
    let* chunked =
      match te with
      | [] -> Ok false
      | [ s ] when String.lowercase_ascii s = "chunked" -> Ok true
      | _ -> Error Unsupported_coding
    in
    if cl <> [] && te <> [] then Error Ambiguous_framing
    else
      let* connection = tokens (values "connection" hs) in
      if
        List.exists forbidden
          (List.filter
             (fun n -> Header.Name.to_string n <> "upgrade")
             connection)
      then Error Invalid_field
      else
        let has_close = List.mem (name "close") connection in
        let* trailer_names = tokens (values "trailer" hs) in
        if
          List.exists
            (fun n -> forbidden n || List.mem n connection)
            trailer_names
          || (trailer_names <> [] && not chunked)
        then Error Invalid_trailer
        else
          let* expect_continue =
            match (head, values "expect" hs) with
            | Request_head _, [] -> Ok false
            | Request_head _, [ s ]
              when String.lowercase_ascii s = "100-continue" ->
                Ok true
            | Request_head _, _ -> Error Unsupported_expectation
            | Response_head _, _ -> Ok false
          in
          let* framing =
            match (role, head) with
            | Request, Request_head _ ->
                Ok
                  (if chunked then Chunked
                   else match length with None -> Empty | Some n -> Fixed n)
            | Response meth, Response_head r ->
                let status = Status.to_int (Response.status r) in
                if
                  status = 101
                  || Method.equal meth Method.connect
                     && status >= 200 && status < 300
                then
                  if cl <> [] || te <> [] then Error Ambiguous_framing
                  else Ok Tunnel
                else if status < 200 || status = 204 then
                  if cl <> [] || te <> [] then Error Ambiguous_framing
                  else Ok Empty
                else if Method.equal meth Method.head || status = 304 then
                  Ok Empty
                else
                  Ok
                    (if chunked then Chunked
                     else
                       match length with
                       | None -> Close_delimited
                       | Some n -> Fixed n)
            | _ -> Error Invalid_state
          in
          let* () =
            match (framing, cfg.body) with
            | Fixed n, Some max when n > max -> Error Limit_exceeded
            | _ -> Ok ()
          in
          Ok
            {
              head;
              framing;
              persistent =
                (not has_close) && framing <> Close_delimited
                && framing <> Tunnel;
              expect_continue;
              trailer_names;
            }

(* A line accumulator scans every byte once. CR is remembered across calls;
   Buffer capacity may be up to twice the configured logical line bound. *)
type line = { buffer : Buffer.t; mutable cr : bool; mutable size : int }

let line () = { buffer = Buffer.create 128; cr = false; size = 0 }

let line_byte t max c =
  if t.size >= max then Error Limit_exceeded
  else (
    t.size <- t.size + 1;
    if t.cr then (
      if c <> '\n' then Error Invalid_line
      else
        let s = Buffer.contents t.buffer in
        Buffer.clear t.buffer;
        t.cr <- false;
        t.size <- 0;
        Ok (Some s))
    else if c = '\r' then (
      t.cr <- true;
      Ok None)
    else if c = '\n' then Error Invalid_line
    else (
      Buffer.add_char t.buffer c;
      Ok None))

let parse_field cfg s =
  match String.index_opt s ':' with
  | None -> Error Invalid_field
  | Some i ->
      let* n =
        core Invalid_field
          (Header.Name.of_string ~max_length:cfg.line (String.sub s 0 i))
      in
      let* v =
        core Invalid_field
          (Header.Value.of_string ~max_length:cfg.line
             (trim (String.sub s (i + 1) (String.length s - i - 1))))
      in
      Ok (Header.create n v)

let field cfg s hs =
  let* h = parse_field cfg s in
  core Limit_exceeded (Headers.add h hs)

let start cfg role s =
  match role with
  | Request -> (
      match String.split_on_char ' ' s with
      | [ meth; target; version ] ->
          if version <> "HTTP/1.1" then Error Unsupported_version
          else
            let* meth =
              core Invalid_line (Method.of_string ~max_length:cfg.line meth)
            in
            let* target =
              core Invalid_target (Target.of_string ~max_length:cfg.line target)
            in
            Ok (Request_head (Request.create ~meth ~target ()))
      | _ -> Error Invalid_line)
  | Response _ ->
      if String.length s < 13 || String.sub s 0 8 <> "HTTP/1.1" then
        Error Unsupported_version
      else if s.[8] <> ' ' || s.[12] <> ' ' then Error Invalid_line
      else
        let* n = decimal (String.sub s 9 3) in
        let* status = core Invalid_line (Status.of_int (Int64.to_int n)) in
        let reason = String.sub s 13 (String.length s - 13) in
        if
          not
            (String.for_all
               (fun c -> c = '\t' || (Char.code c >= 32 && Char.code c <> 127))
               reason)
        then Error Invalid_line
        else Ok (Response_head (Response.create ~status ()))

type head_decoder = {
  cfg : limits;
  role : role;
  line : line;
  mutable bytes : int;
  mutable first : head option;
  mutable fields : Headers.t;
  mutable completed : bool;
  mutable failure : error option;
}

let head_decoder ?(limits = default_limits) role =
  {
    cfg = limits;
    role;
    line = line ();
    bytes = 0;
    first = None;
    fields =
      Result.get_ok
        (Headers.create ~max_fields:limits.fields ~max_bytes:limits.headers ());
    completed = false;
    failure = None;
  }

let feed_head t s ~off ~len =
  let fail e =
    t.failure <- Some e;
    Error e
  in
  if not (slice s off len) then fail Invalid_slice
  else
    match t.failure with
    | Some e -> Error e
    | None ->
        if t.completed then Error Invalid_state
        else
          let stop = min len t.cfg.step in
          let rec loop n =
            if n = stop then Ok (n, None)
            else if t.bytes = t.cfg.headers then fail Limit_exceeded
            else (
              t.bytes <- t.bytes + 1;
              match line_byte t.line t.cfg.line s.[off + n] with
              | Error e -> fail e
              | Ok None -> loop (n + 1)
              | Ok (Some text) -> (
                  match t.first with
                  | None -> (
                      match start t.cfg t.role text with
                      | Error e -> fail e
                      | Ok h ->
                          t.first <- Some h;
                          loop (n + 1))
                  | Some h when text = "" -> (
                      let h =
                        match h with
                        | Request_head r ->
                            Request_head (Request.with_headers t.fields r)
                        | Response_head r ->
                            Response_head (Response.with_headers t.fields r)
                      in
                      match validate t.cfg t.role h with
                      | Error e -> fail e
                      | Ok metadata ->
                          t.completed <- true;
                          Ok (n + 1, Some metadata))
                  | Some _ -> (
                      match field t.cfg text t.fields with
                      | Error e -> fail e
                      | Ok hs ->
                          t.fields <- hs;
                          loop (n + 1))))
          in
          loop 0

let eof_head t =
  match t.failure with
  | Some e -> Error e
  | None ->
      if t.completed then Ok ()
      else (
        t.failure <- Some Unexpected_eof;
        Error Unexpected_eof)

let encode cfg role head first =
  let* metadata = validate cfg role head in
  let fields = Headers.to_list (headers head) in
  if List.length fields > cfg.fields || String.length first > cfg.line then
    Error Limit_exceeded
  else
    let b = Buffer.create 256 in
    let append s =
      if String.length s > cfg.headers - Buffer.length b then
        Error Limit_exceeded
      else (
        Buffer.add_string b s;
        Ok ())
    in
    let* () = append first in
    let rec loop = function
      | [] -> append "\r\n"
      | h :: rest ->
          let n = Header.Name.to_string (Header.name h)
          and v = Header.Value.to_string (Header.value h) in
          if
            String.length n > cfg.line - 4
            || String.length v > cfg.line - 4 - String.length n
          then Error Limit_exceeded
          else
            let* () = append (n ^ ": " ^ v ^ "\r\n") in
            loop rest
    in
    let* () = loop fields in
    Ok (Buffer.contents b, metadata)

let encode_request ?(limits = default_limits) r =
  let meth = Method.to_string (Request.meth r) in
  let target = Target.to_string (Request.target r) in
  (* Check subtraction before concatenating potentially large caller values. *)
  if
    String.length meth > limits.line - 12
    || String.length target > limits.line - 12 - String.length meth
  then Error Limit_exceeded
  else
    encode limits Request
      (Request_head (Request.with_body () r))
      (meth ^ " " ^ target ^ " HTTP/1.1\r\n")

let encode_response ?(limits = default_limits) ~request_method r =
  encode limits (Response request_method)
    (Response_head (Response.with_body () r))
    (Printf.sprintf "HTTP/1.1 %d \r\n" (Status.to_int (Response.status r)))

let chunk_size text =
  let token c = Result.is_ok (Header.Name.of_string (String.make 1 c)) in
  let hex = function
    | '0' .. '9' as c -> Char.code c - 48
    | 'a' .. 'f' as c -> Char.code c - 87
    | 'A' .. 'F' as c -> Char.code c - 55
    | _ -> -1
  in
  let len = String.length text in
  let rec digits i n =
    if i = len || hex text.[i] < 0 then
      if i = 0 then Error Invalid_chunk else Ok (i, n)
    else
      let d = Int64.of_int (hex text.[i]) in
      if n > Int64.div (Int64.sub Int64.max_int d) 16L then Error Invalid_chunk
      else digits (i + 1) (Int64.add (Int64.mul n 16L) d)
  in
  let* i, n = digits 0 0L in
  let rec ows i =
    if i < len && (text.[i] = ' ' || text.[i] = '\t') then ows (i + 1) else i
  in
  let rec tok i = if i < len && token text.[i] then tok (i + 1) else i in
  let rec quoted i =
    if i >= len then Error Invalid_chunk
    else
      match text.[i] with
      | '"' -> Ok (i + 1)
      | '\\' ->
          if
            i + 1 < len
            && (text.[i + 1] = '\t'
               || (Char.code text.[i + 1] >= 32 && Char.code text.[i + 1] <> 127)
               )
          then quoted (i + 2)
          else Error Invalid_chunk
      | c
        when c = '\t' || c = ' ' || c = '!'
             || (Char.code c >= 35 && Char.code c <> 127) ->
          quoted (i + 1)
      | _ -> Error Invalid_chunk
  in
  let rec extensions i =
    if i = len then Ok n
    else
      let j = ows i in
      if j >= len || text.[j] <> ';' then Error Invalid_chunk
      else
        let a = ows (j + 1) in
        let b = tok a in
        if a = b then Error Invalid_chunk
        else
          let c = ows b in
          if c < len && text.[c] = '=' then
            let d = ows (c + 1) in
            let* e =
              if d < len && text.[d] = '"' then quoted (d + 1)
              else
                let e = tok d in
                if e = d then Error Invalid_chunk else Ok e
            in
            extensions e
          else extensions b
  in
  extensions i

type body_event = Data of string | Trailers of Headers.t | End

type body_state =
  | Fixed_left of int64
  | Size
  | Chunk_left of int64
  | Chunk_cr
  | Chunk_lf
  | Trailer_lines
  | Need_end
  | Finished
  | Until_eof
  | Tunnel_state

module Names = Set.Make (String)

let allowed_names meta =
  Names.of_list (List.map Header.Name.to_string meta.trailer_names)

let trailer_allowed allowed h =
  (not (forbidden (Header.name h)))
  && Names.mem (Header.Name.to_string (Header.name h)) allowed

type body_decoder = {
  bcfg : limits;
  allowed : Names.t;
  meta : metadata;
  line : line;
  mutable state : body_state;
  mutable total : int64;
  mutable trailer_bytes : int;
  mutable trailer_fields : Headers.t;
  mutable failure : error option;
}

let body_decoder ?(limits = default_limits) meta =
  let state =
    match meta.framing with
    | Empty | Fixed 0L -> Need_end
    | Fixed n -> Fixed_left n
    | Chunked -> Size
    | Close_delimited -> Until_eof
    | Tunnel -> Tunnel_state
  in
  {
    bcfg = limits;
    allowed = allowed_names meta;
    meta;
    line = line ();
    state;
    total = 0L;
    trailer_bytes = 0;
    trailer_fields =
      Result.get_ok
        (Headers.create ~max_fields:limits.trailer_fields
           ~max_bytes:limits.trailers ());
    failure = None;
  }

let quota cfg total n =
  n <= Int64.sub Int64.max_int total
  && Option.fold ~none:true
       ~some:(fun max -> total <= max && n <= Int64.sub max total)
       cfg.body

let feed_body t s ~off ~len =
  let fail e =
    t.failure <- Some e;
    Error e
  in
  if not (slice s off len) then fail Invalid_slice
  else
    match t.failure with
    | Some e -> Error e
    | None ->
        let stop = min len t.bcfg.step in
        let rec loop n =
          match t.state with
          | Finished | Tunnel_state -> Error Invalid_state
          | Need_end ->
              t.state <- Finished;
              Ok (n, Some End)
          | Fixed_left remaining | Chunk_left remaining ->
              let count =
                Int64.to_int (Int64.min remaining (Int64.of_int (stop - n)))
              in
              data n count (fun () ->
                  let left = Int64.sub remaining (Int64.of_int count) in
                  t.state <-
                    (match t.state with
                    | Fixed_left _ ->
                        if left = 0L then Need_end else Fixed_left left
                    | _ -> if left = 0L then Chunk_cr else Chunk_left left))
          | Until_eof -> data n (stop - n) (fun () -> ())
          | _ when n = stop -> Ok (n, None)
          | Chunk_cr ->
              if s.[off + n] <> '\r' then fail Invalid_chunk
              else (
                t.state <- Chunk_lf;
                loop (n + 1))
          | Chunk_lf ->
              if s.[off + n] <> '\n' then fail Invalid_chunk
              else (
                t.state <- Size;
                loop (n + 1))
          | Size -> (
              match line_byte t.line t.bcfg.chunk_line s.[off + n] with
              | Error e -> fail e
              | Ok None -> loop (n + 1)
              | Ok (Some text) -> (
                  match chunk_size text with
                  | Error e -> fail e
                  | Ok size ->
                      if not (quota t.bcfg t.total size) then
                        fail Limit_exceeded
                      else (
                        t.state <-
                          (if size = 0L then Trailer_lines else Chunk_left size);
                        loop (n + 1))))
          | Trailer_lines ->
              if t.trailer_bytes >= t.bcfg.trailers then fail Limit_exceeded
              else (
                t.trailer_bytes <- t.trailer_bytes + 1;
                match line_byte t.line t.bcfg.line s.[off + n] with
                | Error e -> fail e
                | Ok None -> loop (n + 1)
                | Ok (Some "") ->
                    t.state <- Need_end;
                    Ok (n + 1, Some (Trailers t.trailer_fields))
                | Ok (Some text) -> (
                    match parse_field t.bcfg text with
                    | Error e -> fail e
                    | Ok h -> (
                        if not (trailer_allowed t.allowed h) then
                          fail Invalid_trailer
                        else
                          match
                            core Limit_exceeded (Headers.add h t.trailer_fields)
                          with
                          | Error e -> fail e
                          | Ok hs ->
                              t.trailer_fields <- hs;
                              loop (n + 1))))
        and data n count advance =
          if count = 0 then Ok (n, None)
          else if not (quota t.bcfg t.total (Int64.of_int count)) then
            fail Limit_exceeded
          else
            let bytes = String.sub s (off + n) count in
            t.total <- Int64.add t.total (Int64.of_int count);
            advance ();
            Ok (n + count, Some (Data bytes))
        in
        loop 0

let eof_body t =
  match t.failure with
  | Some e -> Error e
  | None -> (
      match t.state with
      | Finished -> Ok None
      | Need_end | Until_eof ->
          t.state <- Finished;
          Ok (Some End)
      | Tunnel_state -> Error Invalid_state
      | _ ->
          t.failure <- Some Unexpected_eof;
          Error Unexpected_eof)

type body_encoder = {
  ecfg : limits;
  emeta : metadata;
  mutable written : int64;
  mutable terminal : bool;
}

let body_encoder ?(limits = default_limits) emeta =
  { ecfg = limits; emeta; written = 0L; terminal = false }

let encode_data t s =
  let fail e =
    t.terminal <- true;
    Error e
  in
  if t.terminal then Error Invalid_state
  else
    let n = Int64.of_int (String.length s) in
    if String.length s > t.ecfg.step || not (quota t.ecfg t.written n) then
      fail Limit_exceeded
    else
      let* bytes =
        match t.emeta.framing with
        | Empty -> if s = "" then Ok "" else fail Invalid_length
        | Tunnel -> fail Invalid_state
        | Fixed max ->
            if n > Int64.sub max t.written then fail Invalid_length else Ok s
        | Close_delimited -> Ok s
        | Chunked ->
            Ok
              (if s = "" then ""
               else Printf.sprintf "%x\r\n%s\r\n" (String.length s) s)
      in
      t.written <- Int64.add t.written n;
      Ok bytes

let finish_body ?(trailers = Headers.empty) t =
  if t.terminal then Error Invalid_state
  else (
    t.terminal <- true;
    if t.emeta.framing <> Chunked && Headers.length trailers <> 0 then
      Error Invalid_trailer
    else
      match t.emeta.framing with
      | Fixed n when n <> t.written -> Error Invalid_length
      | Tunnel -> Error Invalid_state
      | Chunked ->
          if
            Headers.length trailers > t.ecfg.trailer_fields
            || not
                 (List.for_all
                    (trailer_allowed (allowed_names t.emeta))
                    (Headers.to_list trailers))
          then Error Invalid_trailer
          else
            let b = Buffer.create 128 in
            let rec loop = function
              | [] -> Ok ()
              | h :: rest ->
                  let n = Header.Name.to_string (Header.name h)
                  and v = Header.Value.to_string (Header.value h) in
                  if
                    String.length n > t.ecfg.line - 4
                    || String.length v > t.ecfg.line - 4 - String.length n
                    || String.length n
                       > t.ecfg.trailers - 2 - Buffer.length b - 4
                    || String.length v
                       > t.ecfg.trailers - 2 - Buffer.length b - 4
                         - String.length n
                  then Error Limit_exceeded
                  else (
                    Buffer.add_string b (n ^ ": " ^ v ^ "\r\n");
                    loop rest)
            in
            let* () = loop (Headers.to_list trailers) in
            Ok ("0\r\n" ^ Buffer.contents b ^ "\r\n")
      | _ -> Ok "")
