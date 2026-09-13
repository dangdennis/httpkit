open Lwt.Infix
open Httpkit_core
module W = Httpkit

type 'a t = { store : 'a W.Session.t; mutex : Lwt_mutex.t; ttl : int }

(* Match the deployed Eio cookie identifier across library renames. *)
let name = "__Host-http-kit"

let create ?capacity ~ttl ~(clock : Httpkit_transport_lwt.clock) ~random () =
  if (not (Float.is_finite ttl)) || ttl < 1. || ttl > 31536000. then
    invalid_arg "session TTL";
  let epoch = clock.now () in
  {
    store =
      W.Session.create ?capacity ~ttl
        ~now:(fun () -> clock.now () -. epoch)
        ~random ();
    mutex = Lwt_mutex.create ();
    ttl = int_of_float ttl;
  }

let locked t f = Lwt_mutex.with_lock t.mutex (fun () -> Lwt.return (f ()))

let token request =
  match
    W.Cookie.parse
      (W.Reply.header_values "cookie" (Request.headers (App.head request)))
  with
  | Error _ -> None
  | Ok fields -> (
      match W.Cookie.find name fields with Ok token -> token | _ -> None)

let find t request =
  locked t (fun () -> Option.bind (token request) (W.Session.find t.store))

let attach value max_age response =
  App.map_headers
    (fun headers ->
      Result.get_ok
        (Headers.add
           (Result.get_ok
              (Header.of_strings "set-cookie"
                 (W.Cookie.set ~max_age name value)))
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

let require t next request =
  find t request >>= function
  | Some session -> next session request
  | None ->
      Lwt.return
        (App.reply (W.Reply.text ~status:401 "Authentication required\n"))

let csrf t ~origins next request =
  find t request >>= fun session ->
  let head = App.head request in
  let token_valid input =
    match session with Some s -> W.Session.check_csrf s input | None -> false
  in
  if
    W.Auth.csrf ~allowed_origins:origins ~token_valid ~meth:(Request.meth head)
      (Request.headers head)
  then next request
  else Lwt.return (App.reply (W.Reply.text ~status:403 "CSRF rejected\n"))
