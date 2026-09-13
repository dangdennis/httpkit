exception Error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt
let require condition message = if not condition then fail "%s" message
let ( / ) = Filename.concat
let starts = String.starts_with
let ends = String.ends_with

let contains s part =
  try
    ignore (Str.search_forward (Str.regexp_string part) s 0);
    true
  with Not_found -> false

let rec find_root path =
  if Sys.file_exists (path / "toolchain/manifest.json") then path
  else
    let parent = Filename.dirname path in
    if parent = path then fail "Run from inside the httpkit checkout"
    else find_root parent

let root = find_root (Sys.getcwd ())
let absolute p = if Filename.is_relative p then root / p else p

let read p =
  let ic = open_in_bin p in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let rec mkdir p =
  if p <> "." && not (Sys.file_exists p) then (
    mkdir (Filename.dirname p);
    Unix.mkdir p 0o755)

let write p s =
  mkdir (Filename.dirname p);
  let oc = open_out_bin p in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc s)

let rec files p =
  if not (Sys.file_exists p) then []
  else if Sys.is_directory p then
    Array.to_list (Sys.readdir p)
    |> List.sort String.compare
    |> List.concat_map (fun n ->
        if n = "__pycache__" then [] else files (p / n))
  else [ p ]

let rec remove p =
  match Unix.lstat p with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun n -> remove (p / n)) (Sys.readdir p);
      Unix.rmdir p
  | _ -> Unix.unlink p
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let rec copy src dst =
  if Sys.is_directory src then (
    mkdir dst;
    Array.iter (fun n -> copy (src / n) (dst / n)) (Sys.readdir src))
  else (
    write dst (read src);
    Unix.chmod dst (Unix.stat src).Unix.st_perm)

let temp_dir ?(parent = Filename.get_temp_dir_name ()) prefix =
  mkdir parent;
  let p = Filename.temp_file ~temp_dir:parent prefix "" in
  Unix.unlink p;
  Unix.mkdir p 0o700;
  p

let with_temp prefix f =
  let p = temp_dir prefix in
  Fun.protect ~finally:(fun () -> remove p) (fun () -> f p)

let json p = Yojson.Basic.from_string (read p)
let save p j = write p (Yojson.Basic.pretty_to_string j ^ "\n")

let field key = function
  | `Assoc xs -> Option.value ~default:`Null (List.assoc_opt key xs)
  | _ -> `Null

let string = function
  | `String s -> s
  | j -> fail "Expected string: %s" (Yojson.Basic.to_string j)

let int = function
  | `Int n -> n
  | j -> fail "Expected integer: %s" (Yojson.Basic.to_string j)

let number = function
  | `Int n -> float n
  | `Float f -> f
  | j -> fail "Expected number: %s" (Yojson.Basic.to_string j)

let list = function `List xs -> xs | _ -> []
let assoc = function `Assoc xs -> xs | _ -> []
let strings xs = `List (List.map (fun s -> `String s) xs)
let lines s = String.split_on_char '\n' s |> List.filter (fun s -> s <> "")

let environment () =
  Unix.environment () |> Array.to_list
  |> List.filter_map (fun s ->
      match String.index_opt s '=' with
      | None -> None
      | Some i ->
          Some (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)))

let set env key value = (key, value) :: List.remove_assoc key env
let getenv env key default = Option.value ~default (List.assoc_opt key env)
let env_array env = Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) env)

let clean_ocaml env =
  List.filter
    (fun (k, _) ->
      not
        (List.exists
           (fun prefix -> starts ~prefix k)
           [ "OCAML"; "CAML"; "DUNE" ]))
    env

let sha s = Digestif.SHA256.(to_hex (digest_string s))
let now () = Unix.gettimeofday ()
let sleep seconds = ignore (Unix.select [] [] [] seconds)

let option args name default =
  let rec loop = function
    | a :: v :: _ when a = name -> v
    | _ :: rest -> loop rest
    | [] -> default
  in
  loop args

let flag args name = List.mem name args
let monotonic () = Mtime.Span.to_float_ns (Mtime_clock.elapsed ()) /. 1e9

let validate_options ~values ~flags args =
  let rec loop = function
    | [] -> ()
    | name :: rest when List.mem name flags -> loop rest
    | name :: value :: rest when List.mem name values ->
        require (not (starts ~prefix:"--" value)) ("Missing value for " ^ name);
        loop rest
    | name :: _ -> fail "Unknown option or missing value: %s" name
  in
  loop args
