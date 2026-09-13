module O = Httpkit_oidc
module W = Httpkit
module A = Httpkit_eio
open Httpkit_core

type http_request = {
  meth : [ `GET | `POST ];
  uri : Uri.t;
  headers : (string * string) list;
  body : string;
  max_bytes : int;
}

type http_response = { status : int; body : string }
type error = Busy | Provider_unavailable | Rejected

exception Remote
exception Capacity

type t = {
  config : O.config;
  now : unit -> float;
  random : int -> string;
  http : http_request -> http_response;
  timeout : Eio.Time.Timeout.t;
  capacity : int;
  max_remote : int;
  mutable active : int;
  pending : (string, O.transaction) Hashtbl.t;
  mutex : Eio.Mutex.t;
  mutable provider : (O.provider * float) option;
  mutable keys : (O.keys * float) option;
}

let cookie_name = "__Host-httpkit-oidc"
let clear_cookie = W.Cookie.set ~max_age:0 cookie_name ""

let create ?(capacity = 1024) ?(max_remote = 16) ?(timeout = 10.) ~clock ~now
    ~random ~http config =
  if
    capacity < 1 || capacity > 100000 || max_remote < 1 || max_remote > capacity
    || (not (Float.is_finite timeout))
    || timeout <= 0.
  then invalid_arg "OIDC limits";
  {
    config;
    now;
    random;
    http;
    timeout = Eio.Time.Timeout.seconds clock timeout;
    capacity;
    max_remote;
    active = 0;
    pending = Hashtbl.create (min capacity 1024);
    mutex = Eio.Mutex.create ();
    provider = None;
    keys = None;
  }

let current t =
  let n = t.now () in
  if (not (Float.is_finite n)) || n < 0. then invalid_arg "OIDC clock";
  n

let guarded t f =
  if t.active >= t.max_remote then Error Busy
  else (
    t.active <- t.active + 1;
    Fun.protect
      ~finally:(fun () -> t.active <- t.active - 1)
      (fun () ->
        try Eio.Time.Timeout.run_exn t.timeout f with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | Capacity -> Error Busy
        | _ -> Error Provider_unavailable))

let fetch t request =
  let response = t.http request in
  if response.status <> 200 || String.length response.body > request.max_bytes
  then raise Remote;
  response.body

let get t uri max_bytes =
  fetch t
    {
      meth = `GET;
      uri;
      headers = [ ("accept", "application/json") ];
      body = "";
      max_bytes;
    }

let cache t ~force_keys =
  Eio.Mutex.lock t.mutex;
  Fun.protect
    ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
    (fun () ->
      let now = current t in
      let provider =
        match t.provider with
        | Some (p, until) when now < until -> p
        | _ ->
            let p =
              match
                O.provider t.config (get t (O.discovery_uri t.config) 65536)
              with
              | Ok p -> p
              | Error _ -> raise Remote
            in
            t.provider <- Some (p, now +. 3600.);
            t.keys <- None;
            p
      in
      let keys =
        match t.keys with
        | Some (k, fetched)
          when now < fetched +. 300.
               && ((not force_keys) || now < fetched +. 30.) ->
            k
        | _ ->
            let k =
              match O.keys (get t (O.jwks_uri provider) 262144) with
              | Ok k -> k
              | Error _ -> raise Remote
            in
            t.keys <- Some (k, now);
            k
      in
      (provider, keys))

let prune t now =
  Hashtbl.filter_map_inplace
    (fun _ tx -> if O.expires_at tx <= now then None else Some tx)
    t.pending

let start t =
  guarded t (fun () ->
      let now = current t in
      prune t now;
      if Hashtbl.length t.pending >= t.capacity then raise Capacity;
      let provider, _ = cache t ~force_keys:false in
      (* Reserve only after I/O; another fiber may have filled the store. *)
      if Hashtbl.length t.pending >= t.capacity then raise Capacity;
      let tx, url =
        O.begin_login t.config provider ~now:(current t) ~random:t.random
      in
      if Hashtbl.mem t.pending (O.state tx) then raise Remote;
      Hashtbl.add t.pending (O.state tx) tx;
      Ok (url, W.Cookie.set ~max_age:600 cookie_name (O.binding tx)))

let finish t ~cookies ~query =
  guarded t (fun () ->
      let now = current t in
      prune t now;
      let tx =
        match W.Url.unique "state" query with
        | Ok (Some state) -> Hashtbl.find_opt t.pending state
        | _ -> None
      in
      let browser =
        match W.Cookie.parse cookies with
        | Ok cookies -> (
            match W.Cookie.find cookie_name cookies with
            | Ok value -> value
            | _ -> None)
        | _ -> None
      in
      match (tx, browser) with
      | Some tx, Some browser when O.check_binding tx browser -> (
          match O.callback_code tx ~now query with
          | Error _ ->
              Hashtbl.remove t.pending (O.state tx);
              Error Rejected
          | Ok code -> (
              Hashtbl.remove t.pending (O.state tx);
              let provider, keys = cache t ~force_keys:false in
              let request = O.token_request t.config provider tx ~code in
              let body =
                fetch t
                  {
                    meth = `POST;
                    uri = request.uri;
                    headers = request.headers;
                    body = request.body;
                    max_bytes = 65536;
                  }
              in
              match O.id_token body with
              | Error _ -> Error Rejected
              | Ok token ->
                  let validate keys =
                    O.validate t.config keys tx ~now:(current t) token
                  in
                  let result =
                    match validate keys with
                    | Error O.Unknown_key ->
                        let _, keys = cache t ~force_keys:true in
                        validate keys
                    | result -> result
                  in
                  Result.map_error (fun _ -> Rejected) result))
      | _ -> Error Rejected)

let attach cookie response =
  A.map_headers
    (fun headers ->
      Result.get_ok
        (Headers.add
           (Result.get_ok (Header.of_strings "set-cookie" cookie))
           headers))
    response

let failure = function
  | Busy -> A.reply (W.Reply.text ~status:503 "Login capacity unavailable\n")
  | Provider_unavailable ->
      A.reply (W.Reply.text ~status:502 "Identity provider unavailable\n")
  | Rejected -> A.reply (W.Reply.text ~status:400 "Login rejected\n")

let login t request =
  if Request.meth (A.head request) <> Method.get then
    A.reply (W.Reply.text ~status:405 "GET required\n")
  else
    match start t with
    | Ok (url, cookie) ->
        attach cookie
          (A.reply
             (W.Reply.make ~status:303
                ~headers:[ ("location", Uri.to_string url) ]
                ""))
    | Error e -> failure e

let callback t ~on_login request =
  let head = A.head request in
  let response =
    if Request.meth head <> Method.get then
      A.reply (W.Reply.text ~status:405 "GET required\n")
    else
      match
        W.Url.query ~max_bytes:8192 ~max_fields:16
          (Target.to_string (Request.target head))
      with
      | Error _ -> failure Rejected
      | Ok query -> (
          match
            finish t
              ~cookies:(W.Reply.header_values "cookie" (Request.headers head))
              ~query
          with
          | Ok identity -> on_login identity request
          | Error e -> failure e)
  in
  attach clear_cookie response
