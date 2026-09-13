type 'a session = { token : string; csrf : string; value : 'a; expires : float }

type 'a t = {
  capacity : int;
  ttl : float;
  now : unit -> float;
  random : int -> string;
  entries : (string, 'a session) Hashtbl.t;
}

let create ?(capacity = 1024) ~ttl ~now ~random () =
  if capacity <= 0 || (not (Float.is_finite ttl)) || ttl <= 0. then
    invalid_arg "session limits";
  { capacity; ttl; now; random; entries = Hashtbl.create (min capacity 1024) }

let key token = Digestif.SHA256.(to_hex (digest_string token))

let fresh t =
  let raw = t.random 32 in
  if String.length raw <> 32 then invalid_arg "random source length";
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet raw

let prune t =
  let now = t.now () in
  if not (Float.is_finite now) then invalid_arg "session clock";
  Hashtbl.filter_map_inplace
    (fun _ s -> if s.expires <= now then None else Some s)
    t.entries;
  now

let issue t value =
  let now = prune t in
  if Hashtbl.length t.entries >= t.capacity then Error "session capacity"
  else
    let token = fresh t in
    if Hashtbl.mem t.entries (key token) then Error "random token collision"
    else
      let session = { token; csrf = fresh t; value; expires = now +. t.ttl } in
      Hashtbl.add t.entries (key token) session;
      Ok session

let find t token =
  ignore (prune t);
  if String.length token <> 43 then None
  else Hashtbl.find_opt t.entries (key token)

let revoke t token = Hashtbl.remove t.entries (key token)

let rotate t previous value =
  match find t previous.token with
  | None -> Error "expired session"
  | Some current when current != previous -> Error "foreign session"
  | Some _ -> (
      (* Free one slot, restoring the old session if token creation fails. *)
      revoke t previous.token;
      match issue t value with
      | Ok next when next.token <> previous.token -> Ok next
      | Ok _ ->
          Hashtbl.replace t.entries (key previous.token) previous;
          Error "rotation collision"
      | Error e ->
          Hashtbl.add t.entries (key previous.token) previous;
          Error e
      | exception exn ->
          Hashtbl.add t.entries (key previous.token) previous;
          raise exn)

let token s = s.token
let csrf s = s.csrf
let value s = s.value
let check_csrf s input = String.length input = 43 && Eqaf.equal s.csrf input

let count t =
  ignore (prune t);
  Hashtbl.length t.entries
