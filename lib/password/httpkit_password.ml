external linked : unit -> bool = "httpkit_argon2_link"

let () = if not (linked ()) then failwith "libargon2 unavailable"

type t = { memory : int; iterations : int }
type error = Invalid_password | Invalid_hash | Invalid_entropy | Backend_error

let create ?(memory_kib = 65536) ?(iterations = 3) () =
  if
    memory_kib < 19456 || memory_kib > 262144 || iterations < 2
    || iterations > 10
  then invalid_arg "Argon2 policy";
  { memory = memory_kib; iterations }

let password s =
  String.length s > 0
  && String.length s <= 1024
  && not (String.contains s '\000')

let decimal s =
  if
    s = ""
    || String.length s > 8
    || not (String.for_all (fun c -> c >= '0' && c <= '9') s)
  then None
  else int_of_string_opt s

let parameter prefix s =
  if String.starts_with ~prefix s then
    decimal
      (String.sub s (String.length prefix)
         (String.length s - String.length prefix))
  else None

let inspect encoded =
  if String.length encoded > 512 || String.contains encoded '\000' then
    Error Invalid_hash
  else
    match String.split_on_char '$' encoded with
    | [ ""; "argon2id"; "v=19"; params; salt; digest ] -> (
        match String.split_on_char ',' params with
        | [ m; t; p ] -> (
            match (parameter "m=" m, parameter "t=" t, parameter "p=" p) with
            | Some m, Some t, Some p
              when m >= 8 * p
                   && m <= 262144 && t >= 1 && t <= 10 && p >= 1 && p <= 4 ->
                let base64 s =
                  String.for_all
                    (function
                      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '+' | '/' -> true
                      | _ -> false)
                    s
                in
                if
                  String.length salt < 11
                  || String.length salt > 86
                  || String.length digest < 22
                  || String.length digest > 86
                  || not (base64 salt && base64 digest)
                then Error Invalid_hash
                else Ok (m, t, p, String.length salt, String.length digest)
            | _ -> Error Invalid_hash)
        | _ -> Error Invalid_hash)
    | _ -> Error Invalid_hash

let hash t ~random pwd =
  if not (password pwd) then Error Invalid_password
  else
    let salt = random 16 in
    if String.length salt <> 16 then Error Invalid_entropy
    else
      let encoded_len =
        Argon2.encoded_len ~t_cost:t.iterations ~m_cost:t.memory ~parallelism:1
          ~salt_len:16 ~hash_len:32 ~kind:Argon2.ID
      in
      match
        Argon2.hash ~t_cost:t.iterations ~m_cost:t.memory ~parallelism:1 ~pwd
          ~salt ~kind:Argon2.ID ~hash_len:32 ~encoded_len
          ~version:Argon2.VERSION_13
      with
      | Ok (_, encoded) -> Ok encoded
      | Error _ -> Error Backend_error

let verify _ ~encoded pwd =
  if not (password pwd) then Error Invalid_password
  else
    match inspect encoded with
    | Error e -> Error e
    | Ok _ -> (
        match Argon2.verify ~encoded ~pwd ~kind:Argon2.ID with
        | Ok result -> Ok result
        | Error Argon2.ErrorCodes.VERIFY_MISMATCH -> Ok false
        | Error _ -> Error Invalid_hash)

let needs_rehash t encoded =
  Result.map
    (fun (m, i, p, s, h) ->
      m <> t.memory || i <> t.iterations || p <> 1 || s <> 22 || h <> 43)
    (inspect encoded)
