open Httpkit_core
module W = Httpkit

type 'a t = { store : 'a W.Session.t; mutex : Eio.Mutex.t; ttl : int }

let name = "__Host-http-kit"

let create ?capacity ~ttl ~clock ~random () =
  if (not (Float.is_finite ttl)) || ttl < 1. || ttl > 31536000. then
    invalid_arg "session TTL";
  let epoch = Eio.Time.Mono.now clock in
  let now () =
    Mtime.Span.to_float_ns (Mtime.span epoch (Eio.Time.Mono.now clock)) /. 1e9
  in
  {
    store = W.Session.create ?capacity ~ttl ~now ~random ();
    mutex = Eio.Mutex.create ();
    ttl = int_of_float ttl;
  }

let locked t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let token request =
  match
    W.Cookie.parse
      (W.Reply.header_values "cookie" (Request.headers (App.head request)))
  with
  | Error _ -> None
  | Ok fields -> (
      match W.Cookie.find name fields with Ok token -> token | Error _ -> None)

let find t request =
  locked t (fun () ->
      match token request with
      | None -> None
      | Some token -> W.Session.find t.store token)

let attach value max_age response =
  App.map_headers
    (fun headers ->
      let cookie = W.Cookie.set ~same_site:W.Cookie.Lax ~max_age name value in
      Result.get_ok
        (Headers.add
           (Result.get_ok (Header.of_strings "set-cookie" cookie))
           headers))
    response

let login t user response =
  locked t (fun () ->
      match W.Session.issue t.store user with
      | Ok session -> attach (W.Session.token session) t.ttl response
      | Error _ ->
          App.reply (W.Reply.text ~status:503 "Session capacity unavailable\n"))

let logout t request response =
  locked t (fun () ->
      Option.iter (W.Session.revoke t.store) (token request);
      attach "" 0 response)

let rotate t request user response =
  locked t (fun () ->
      match Option.bind (token request) (W.Session.find t.store) with
      | None -> App.reply (W.Reply.text ~status:401 "Authentication required\n")
      | Some old -> (
          match W.Session.rotate t.store old user with
          | Ok session -> attach (W.Session.token session) t.ttl response
          | Error _ ->
              App.reply (W.Reply.text ~status:503 "Session unavailable\n")))

let require t endpoint request =
  match find t request with
  | None -> App.reply (W.Reply.text ~status:401 "Authentication required\n")
  | Some session -> endpoint session request

let csrf t ~origins next request =
  let head = App.head request in
  let token_valid input =
    match find t request with
    | None -> false
    | Some session -> W.Session.check_csrf session input
  in
  if
    W.Auth.csrf ~allowed_origins:origins ~token_valid ~meth:(Request.meth head)
      (Request.headers head)
  then next request
  else App.reply (W.Reply.text ~status:403 "CSRF rejected\n")
