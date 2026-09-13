module D = Httpkit_db_eio
module W = Httpkit
module A = Httpkit_eio
open Httpkit_core

let sql =
  [
    "CREATE TABLE httpkit_sessions (namespace VARCHAR(128) NOT NULL, \
     token_hash VARCHAR(64) NOT NULL, subject VARCHAR(256) NOT NULL, value \
     TEXT NOT NULL, csrf VARCHAR(43) NOT NULL, expires BIGINT NOT NULL, \
     PRIMARY KEY(namespace, token_hash))";
    "CREATE INDEX httpkit_sessions_expiry ON httpkit_sessions(namespace, \
     expires)";
    "CREATE INDEX httpkit_sessions_subject ON httpkit_sessions(namespace, \
     subject)";
  ]

let migration ~version = { D.version; postgresql = sql; sqlite = sql }

type t = {
  db : D.t;
  namespace : string;
  name : string;
  max_payload : int;
  ttl : int;
  now : unit -> float;
  random : int -> string;
}

type session = {
  token : string;
  value : string;
  subject : string;
  csrf : string;
  expires : int64;
}

let create ?(name = "__Host-httpkit") ?(max_payload = 8192) ~namespace ~ttl ~now
    ~random db =
  if
    namespace = ""
    || String.length namespace > 128
    || String.contains namespace '\000'
    || max_payload < 0 || max_payload > 1048576 || ttl < 1 || ttl > 2592000
    || not (String.starts_with ~prefix:"__Host-" name)
  then invalid_arg "SQL session configuration";
  ignore (W.Cookie.set name "");
  { db; namespace; name; max_payload; ttl; now; random }

let now t =
  let n = t.now () in
  if (not (Float.is_finite n)) || n < 0. || n > 253402300799. then
    invalid_arg "session clock";
  Int64.of_float n

let token s = s.token
let value s = s.value
let subject s = s.subject
let csrf s = s.csrf
let expires_at s = s.expires
let check_csrf s input = Eqaf.equal s.csrf input

let token_valid s =
  String.length s = 43
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true | _ -> false)
       s

let digest s = Digestif.SHA256.(to_hex (digest_string s))

let fresh t =
  let s = t.random 32 in
  if String.length s <> 32 then invalid_arg "session entropy";
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let prepare t ~subject value =
  if
    subject = ""
    || String.length subject > 256
    || String.contains subject '\000'
    || (not (String.is_valid_utf_8 subject))
    || String.contains value '\000'
    || (not (String.is_valid_utf_8 value))
    || String.length value > t.max_payload
  then invalid_arg "session value";
  {
    token = fresh t;
    csrf = fresh t;
    subject;
    value;
    expires = Int64.add (now t) (Int64.of_int t.ttl);
  }

module Q = struct
  open Caqti.Templater

  let insert =
    static
      T.(t2 (t3 string string string) (t3 string string int64) -->? string)
      "INSERT INTO httpkit_sessions(namespace, token_hash, subject, value, \
       csrf, expires) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(namespace, \
       token_hash) DO NOTHING RETURNING token_hash"

  let find =
    static
      T.(t3 string string int64 -->? t4 string string string int64)
      "SELECT subject, value, csrf, expires FROM httpkit_sessions WHERE \
       namespace=? AND token_hash=? AND expires>?"

  let rotate =
    static
      T.(
        t2 (t4 string string string string) (t4 int64 string string int64)
        -->? string)
      "UPDATE httpkit_sessions SET token_hash=?, subject=?, value=?, csrf=?, \
       expires=? WHERE namespace=? AND token_hash=? AND expires>? RETURNING \
       token_hash"

  let revoke =
    static
      T.(t2 string string -->. unit)
      "DELETE FROM httpkit_sessions WHERE namespace=? AND token_hash=?"

  let subject =
    static
      T.(t2 string string -->. unit)
      "DELETE FROM httpkit_sessions WHERE namespace=? AND subject=?"

  let prune =
    static
      T.(t4 string string int64 int -->. unit)
      "DELETE FROM httpkit_sessions WHERE namespace=? AND token_hash IN \
       (SELECT token_hash FROM httpkit_sessions WHERE namespace=? AND \
       expires<=? ORDER BY expires LIMIT ?)"
end

let run t f =
  D.use t.db (fun (module C : Caqti_eio.CONNECTION) ->
      f (module C : Caqti_eio.CONNECTION))

let issue t ~subject value =
  let rec attempt n =
    let s = prepare t ~subject value in
    let added =
      run t (fun (module C) ->
          Caqti_eio.or_fail
            (C.find_opt Q.insert
               ( (t.namespace, digest s.token, s.subject),
                 (s.value, s.csrf, s.expires) )))
    in
    match added with
    | Some _ -> s
    | None when n > 0 -> attempt (n - 1)
    | None -> failwith "session entropy collision"
  in
  attempt 2

let find t token =
  if not (token_valid token) then None
  else
    let current = now t in
    run t (fun (module C) ->
        Caqti_eio.or_fail
          (C.find_opt Q.find (t.namespace, digest token, current)))
    |> Option.map (fun (subject, value, csrf, expires) ->
        if String.length value > t.max_payload || not (token_valid csrf) then
          failwith "invalid stored session";
        { token; subject; value; csrf; expires })

let rotate t old ~subject value =
  if not (token_valid old) then None
  else
    let s = prepare t ~subject value in
    if Eqaf.equal old s.token then failwith "session entropy collision";
    let current = now t in
    let changed =
      run t (fun (module C) ->
          Caqti_eio.or_fail
            (C.find_opt Q.rotate
               ( (digest s.token, s.subject, s.value, s.csrf),
                 (s.expires, t.namespace, digest old, current) )))
    in
    Option.map (fun _ -> s) changed

let revoke t token =
  if token_valid token then
    run t (fun (module C) ->
        Caqti_eio.or_fail (C.exec Q.revoke (t.namespace, digest token)))

let revoke_subject t subject =
  run t (fun (module C) ->
      Caqti_eio.or_fail (C.exec Q.subject (t.namespace, subject)))

let prune ?(limit = 1000) t =
  if limit < 1 || limit > 10000 then invalid_arg "prune limit";
  let current = now t in
  run t (fun (module C) ->
      Caqti_eio.or_fail
        (C.exec Q.prune (t.namespace, t.namespace, current, limit)))

let request_token t r =
  match
    W.Cookie.parse (W.Reply.header_values "cookie" (Request.headers (A.head r)))
  with
  | Error _ -> None
  | Ok cookies -> (
      match W.Cookie.find t.name cookies with
      | Ok token -> token
      | Error _ -> None)

let of_request t r = Option.bind (request_token t r) (find t)

let set t token age response =
  A.map_headers
    (fun headers ->
      Result.get_ok
        (Headers.add
           (Result.get_ok
              (Header.of_strings "set-cookie"
                 (W.Cookie.set ~max_age:age t.name token)))
           headers))
    response

let attach t s response =
  set t s.token
    (Int64.to_int (Int64.max 0L (Int64.sub s.expires (now t))))
    response

let logout t request response =
  Option.iter (revoke t) (request_token t request);
  set t "" 0 response

let require t next r =
  match of_request t r with
  | Some s -> next s r
  | None -> A.reply (W.Reply.text ~status:401 "Authentication required\n")

let protect_csrf t ~origins next r =
  let h = A.head r in
  let token_valid input =
    match of_request t r with Some s -> check_csrf s input | None -> false
  in
  if
    W.Auth.csrf ~allowed_origins:origins ~token_valid ~meth:(Request.meth h)
      (Request.headers h)
  then next r
  else A.reply (W.Reply.text ~status:403 "CSRF rejected\n")
