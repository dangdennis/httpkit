type role = Client | Server

type config = {
  incoming_limit : int;
  outgoing_limit : int;
  header_deadline_ns : int64;
  max_steps : int;
}

type action =
  | Open of int
  | Begin of int * int * int
  | Input of int * string
  | Consume of int * int
  | Send of int * int * string
  | Write of int * int
  | Finish of int
  | Wait_body of int
  | Cancel of int
  | Eof of int
  | Read_error of int
  | Write_error of int
  | Shutdown of int
  | Run of int * int
  | Advance of int64

type t = {
  id : string;
  role : role;
  seed : string;
  config : config;
  actions : action list;
}

let default_config =
  {
    incoming_limit = 8;
    outgoing_limit = 8;
    header_deadline_ns = 10L;
    max_steps = 10000;
  }

let max_encoded_bytes = 8 * 1024 * 1024

let connection = function
  | Advance _ -> None
  | Open c
  | Begin (c, _, _)
  | Input (c, _)
  | Consume (c, _)
  | Send (c, _, _)
  | Write (c, _)
  | Finish c
  | Wait_body c
  | Cancel c
  | Eof c
  | Read_error c
  | Write_error c
  | Shutdown c
  | Run (c, _) ->
      Some c

let valid_id s =
  String.length s > 0
  && String.length s <= 100
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       s
  && s <> "." && s <> ".."

exception Invalid of string

let check b msg = if not b then raise (Invalid msg)

let validate s =
  try
    check (valid_id s.id) "unsafe or empty scenario ID";
    check (String.length s.seed <= 100) "seed too long";
    check
      (s.config.incoming_limit > 0 && s.config.incoming_limit <= 1048576)
      "incoming limit out of range";
    check
      (s.config.outgoing_limit > 0 && s.config.outgoing_limit <= 1048576)
      "outgoing limit out of range";
    check (s.config.header_deadline_ns > 0L) "deadline must be positive";
    check
      (s.config.max_steps > 0 && s.config.max_steps <= 100000)
      "step budget out of range";
    check (List.length s.actions <= 4096) "too many actions";
    let opened = Hashtbl.create 8 and begun = Hashtbl.create 8 in
    let now = ref 0L and bytes = ref 0 in
    List.iter
      (fun a ->
        (match connection a with
        | None -> ()
        | Some c -> (
            check (c >= 0 && c < 8) "connection ID out of range";
            match a with
            | Open _ ->
                check (not (Hashtbl.mem opened c)) "duplicate open";
                Hashtbl.add opened c ()
            | _ -> check (Hashtbl.mem opened c) "action before open"));
        (match a with
        | Begin (c, m, n) ->
            check
              (m >= 0 && n >= 0 && n <= 1048576)
              "message/length out of range";
            Hashtbl.replace begun c ()
        | Consume (c, n) | Write (c, n) ->
            check (n >= 0 && n <= 1048576) "count out of range";
            if match a with Consume _ -> true | _ -> false then
              check (Hashtbl.mem begun c) "consume before begin"
        | Finish c | Wait_body c ->
            check (Hashtbl.mem begun c) "body action before begin"
        | Send (_, token, data) ->
            check (token >= 0) "negative token";
            bytes := !bytes + String.length data
        | Input (_, data) -> bytes := !bytes + String.length data
        | Run (_, n) -> check (n > 0 && n <= 100000) "run budget out of range"
        | Advance ns ->
            check
              (ns >= 0L && ns <= Int64.sub Int64.max_int !now)
              "clock overflow";
            now := Int64.add !now ns
        | _ -> ());
        check (!bytes <= 1048576) "decoded data exceeds 1 MiB";
        check
          (!now <= Int64.sub Int64.max_int s.config.header_deadline_ns)
          "deadline overflow")
      s.actions;
    Ok ()
  with Invalid e -> Error e

let num n = `String (string_of_int n)
let ns n = `String (Int64.to_string n)
let obj x = `Assoc x

let action_to_json a =
  let a0 name c = obj [ ("op", `String name); ("connection", num c) ] in
  let a1 name c key v =
    obj [ ("op", `String name); ("connection", num c); (key, v) ]
  in
  match a with
  | Open c -> a0 "open" c
  | Finish c -> a0 "finish" c
  | Wait_body c -> a0 "wait_body" c
  | Cancel c -> a0 "cancel" c
  | Eof c -> a0 "eof" c
  | Read_error c -> a0 "read_error" c
  | Write_error c -> a0 "write_error" c
  | Shutdown c -> a0 "shutdown" c
  | Begin (c, m, n) ->
      obj
        [
          ("op", `String "begin");
          ("connection", num c);
          ("message", num m);
          ("length", num n);
        ]
  | Input (c, s) -> a1 "input" c "data" (`String (Base64.encode_exn s))
  | Consume (c, n) -> a1 "consume" c "count" (num n)
  | Write (c, n) -> a1 "write" c "count" (num n)
  | Run (c, n) -> a1 "run" c "budget" (num n)
  | Send (c, t, s) ->
      obj
        [
          ("op", `String "send");
          ("connection", num c);
          ("token", num t);
          ("data", `String (Base64.encode_exn s));
        ]
  | Advance n -> obj [ ("op", `String "advance"); ("ns", ns n) ]

let to_json s =
  obj
    [
      ("schema", `Int 1);
      ("generator", `String "materialized-v1");
      ("id", `String s.id);
      ( "role",
        `String (match s.role with Client -> "client" | Server -> "server") );
      ("seed", `String s.seed);
      ( "config",
        obj
          [
            ("incoming_limit", num s.config.incoming_limit);
            ("outgoing_limit", num s.config.outgoing_limit);
            ("header_deadline_ns", ns s.config.header_deadline_ns);
            ("max_steps", num s.config.max_steps);
          ] );
      ("actions", `List (List.map action_to_json s.actions));
    ]

let fields allowed = function
  | `Assoc xs ->
      let keys = List.map fst xs in
      check
        (List.length keys = List.length (List.sort_uniq String.compare keys))
        "duplicate JSON key";
      check
        (List.sort String.compare keys = List.sort String.compare allowed)
        "missing or unknown JSON key";
      xs
  | _ -> raise (Invalid "expected JSON object")

let get xs k = List.assoc k xs
let str = function `String s -> s | _ -> raise (Invalid "expected string")

let number j =
  let s = str j in
  check
    (String.length s > 0
    && String.length s <= 19
    && String.for_all (function '0' .. '9' -> true | _ -> false) s)
    "expected unsigned decimal string";
  try Int64.of_string s with Failure _ -> raise (Invalid "integer overflow")

let integer j =
  let n = number j in
  check (n <= Int64.of_int max_int) "native integer overflow";
  Int64.to_int n

let data j =
  let encoded = str j in
  match Base64.decode encoded with
  | Ok s when Base64.encode_exn s = encoded -> s
  | _ -> raise (Invalid "invalid or noncanonical base64")

let parse_action j =
  let raw =
    match j with `Assoc xs -> xs | _ -> raise (Invalid "expected action")
  in
  let op =
    try str (get raw "op") with Not_found -> raise (Invalid "missing op")
  in
  let keys =
    match op with
    | "advance" -> [ "op"; "ns" ]
    | "begin" -> [ "op"; "connection"; "message"; "length" ]
    | "input" -> [ "op"; "connection"; "data" ]
    | "send" -> [ "op"; "connection"; "token"; "data" ]
    | "consume" | "write" -> [ "op"; "connection"; "count" ]
    | "run" -> [ "op"; "connection"; "budget" ]
    | "open" | "finish" | "wait_body" | "cancel" | "eof" | "read_error"
    | "write_error" | "shutdown" ->
        [ "op"; "connection" ]
    | _ -> raise (Invalid "unknown operation")
  in
  let f = fields keys j in
  let c () = integer (get f "connection") and n k = integer (get f k) in
  match op with
  | "open" -> Open (c ())
  | "begin" -> Begin (c (), n "message", n "length")
  | "input" -> Input (c (), data (get f "data"))
  | "consume" -> Consume (c (), n "count")
  | "send" -> Send (c (), n "token", data (get f "data"))
  | "write" -> Write (c (), n "count")
  | "finish" -> Finish (c ())
  | "wait_body" -> Wait_body (c ())
  | "cancel" -> Cancel (c ())
  | "eof" -> Eof (c ())
  | "read_error" -> Read_error (c ())
  | "write_error" -> Write_error (c ())
  | "shutdown" -> Shutdown (c ())
  | "run" -> Run (c (), n "budget")
  | "advance" -> Advance (number (get f "ns"))
  | _ -> assert false

(* Bound nesting before invoking the recursive JSON parser, respecting strings. *)
let check_depth s =
  let depth = ref 0 and quoted = ref false and escaped = ref false in
  String.iter
    (fun c ->
      if !quoted then (
        if !escaped then escaped := false
        else if c = '\\' then escaped := true
        else if c = '"' then quoted := false)
      else if c = '"' then quoted := true
      else if c = '{' || c = '[' then (
        incr depth;
        check (!depth <= 32) "JSON depth exceeds 32")
      else if c = '}' || c = ']' then decr depth)
    s

let of_string text =
  try
    check
      (String.length text <= max_encoded_bytes)
      "encoded scenario exceeds 8 MiB";
    check_depth text;
    let f =
      fields
        [ "schema"; "generator"; "id"; "role"; "seed"; "config"; "actions" ]
        (Yojson.Safe.from_string text)
    in
    check
      (get f "schema" = `Int 1 && get f "generator" = `String "materialized-v1")
      "unsupported schema/generator";
    let c =
      fields
        [
          "incoming_limit"; "outgoing_limit"; "header_deadline_ns"; "max_steps";
        ]
        (get f "config")
    in
    let config =
      {
        incoming_limit = integer (get c "incoming_limit");
        outgoing_limit = integer (get c "outgoing_limit");
        header_deadline_ns = number (get c "header_deadline_ns");
        max_steps = integer (get c "max_steps");
      }
    in
    let role =
      match get f "role" with
      | `String "client" -> Client
      | `String "server" -> Server
      | _ -> raise (Invalid "invalid role")
    in
    let actions =
      match get f "actions" with
      | `List xs ->
          check (List.length xs <= 4096) "too many actions";
          List.map parse_action xs
      | _ -> raise (Invalid "expected actions array")
    in
    let s =
      {
        id = str (get f "id");
        role;
        seed = str (get f "seed");
        config;
        actions;
      }
    in
    match validate s with Ok () -> Ok s | Error e -> Error e
  with
  | Invalid e -> Error e
  | Yojson.Json_error _ -> Error "invalid JSON"

let load path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let b = Buffer.create 4096 and chunk = Bytes.create 4096 in
        let rec read () =
          let n = input ic chunk 0 4096 in
          if Buffer.length b + n > max_encoded_bytes then
            Error "encoded scenario exceeds 8 MiB"
          else if n = 0 then of_string (Buffer.contents b)
          else (
            Buffer.add_subbytes b chunk 0 n;
            read ())
        in
        read ())
  with Sys_error e -> Error e

let save path s =
  match validate s with
  | Error e -> invalid_arg e
  | Ok () ->
      let oc = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          Yojson.Safe.pretty_to_channel oc (to_json s);
          output_char oc '\n')
