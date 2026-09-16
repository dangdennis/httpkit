open Httpkit_core
module A = Httpkit_transport_eio
module E = Httpkit_engine

type upload = {
  length : int64 option;
  produce : unit -> string option;
  mutable used : bool;
}

let upload ?length produce =
  if Option.fold ~none:false ~some:(fun n -> n < 0L) length then
    invalid_arg "httpkit client: negative upload length";
  { length; produce; used = false }

let framing = function
  | None -> `Empty
  | Some u -> ( match u.length with None -> `Chunked | Some n -> `Fixed n)

let claim_upload = function
  | None -> ()
  | Some u ->
      if u.used then invalid_arg "httpkit client: upload already used";
      u.used <- true

type body = {
  next : unit -> string option;
  mutable open_ : bool;
  mutable busy : bool;
  mutable ended : bool;
  trailers : Headers.t option ref;
}

let read body =
  if (not body.open_) || body.busy then
    invalid_arg "httpkit client: body outside scope or concurrent read";
  if body.ended then None
  else (
    body.busy <- true;
    Fun.protect
      ~finally:(fun () -> body.busy <- false)
      (fun () ->
        let chunk = body.next () in
        if chunk = None then body.ended <- true;
        chunk))

let trailers body =
  if body.ended then Some (Option.value !(body.trailers) ~default:Headers.empty)
  else None

let engine_ok = function Ok x -> x | Error e -> raise (A.Error (A.Engine e))

exception Pool_exhausted

type pool = {
  origin : Httpkit_client.endpoint;
  connect : unit -> A.transport;
  now : unit -> float;
  within : 'a. float -> (unit -> 'a) -> 'a;
  drive : 'a. A.transport -> E.t -> (A.connection -> 'a) -> 'a;
  limits : Httpkit_http1.limits option;
  max_connections : int;
  idle_timeout : float;
  keep_alive : bool;
  mutable open_pool : bool;
  mutable busy_count : int;
  mutable idle : (A.transport * float) list;
  mutable active : (Eio.Cancel.t * unit Eio.Promise.t) list;
}

(* Translate raw EOF before handing bytes to TLS. The upstream TLS engine alone
   interprets authenticated close_notify; its clean EOF remains End_of_file. *)
module Guarded_flow = struct
  type t = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r

  let single_read t b =
    try Eio.Flow.single_read t b
    with End_of_file -> raise Httpkit_client.Tls_truncated

  let single_write = Eio.Flow.single_write
  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
  let read_methods = []
  let shutdown = Eio.Flow.shutdown
  let close = Eio.Flow.close
end

let guarded_flow raw =
  let handler =
    Eio.Resource.handler
      [
        H (Eio.Flow.Pi.Source, (module Guarded_flow));
        H (Eio.Flow.Pi.Sink, (module Guarded_flow));
        H (Eio.Flow.Pi.Shutdown, (module Guarded_flow));
        H (Eio.Resource.Close, Guarded_flow.close);
      ]
  in
  Eio.Resource.T ((raw :> Guarded_flow.t), handler)

let connect ~sw ~net ~clock ~authenticator (endpoint : Httpkit_client.endpoint)
    =
  let addresses =
    Eio.Net.getaddrinfo_stream net endpoint.Httpkit_client.host
      ~service:(string_of_int endpoint.port)
  in
  let rec attempt last = function
    | [] -> raise last
    | addr :: rest -> (
        match Eio.Net.connect ~sw net addr with
        | raw -> raw
        | exception (Eio.Io _ as e) -> attempt e rest)
  in
  let raw = attempt (Failure "httpkit client: no stream addresses") addresses in
  try
    let transport =
      if not endpoint.tls then A.of_flow raw
      else
        let config =
          match
            Tls.Config.client ~authenticator ~alpn_protocols:[ "http/1.1" ] ()
          with
          | Ok c -> c
          | Error (`Msg m) -> invalid_arg m
        in
        let host, ip =
          match Ipaddr.of_string endpoint.host with
          | Ok ip -> (None, Some ip)
          | Error _ ->
              ( Some
                  (Domain_name.host_exn
                     (Domain_name.of_string_exn endpoint.host)),
                None )
        in
        let flow = Tls_eio.client_of_flow config ?host ?ip (guarded_flow raw) in
        let transport = A.of_flow flow in
        {
          transport with
          close =
            (fun () ->
              Fun.protect ~finally:transport.close (fun () ->
                  (* Teardown must not wait indefinitely for a TLS write. *)
                  try
                    Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock 1.)
                      (fun () -> Eio.Flow.shutdown flow `Send)
                  with _ -> ()));
        }
    in
    let closed = ref false in
    {
      transport with
      close =
        (fun () ->
          if not !closed then (
            closed := true;
            Eio.Cancel.protect transport.close));
    }
  with e ->
    Eio.Flow.close raw;
    raise e

let prepare ?headers ?meth ?upload ~keep_alive url =
  match
    Httpkit_client.prepare ?headers ?meth ~body:(framing upload) ~keep_alive url
  with
  | Ok x -> x
  | Error e -> invalid_arg e

let exchange ?upload (endpoint : Httpkit_client.endpoint) engine connection
    reusable f =
  let id = A.submit_request connection endpoint.request in
  let command f =
    try f ()
    with
    | A.Error (A.Engine E.Invalid_command) when E.upload_aborted engine id ->
      (* A final head is pending for the response owner, which cancels and
           joins this producer. Never swallow a framing/transport failure. *)
      Eio.Fiber.await_cancel ()
  in
  let send () =
    let rec loop u =
      match u.produce () with
      | None -> command (fun () -> A.finish connection id)
      | Some bytes ->
          if bytes = "" || String.length bytes > 65536 then
            invalid_arg "httpkit client: upload chunks must be 1..65536 bytes";
          command (fun () -> A.send connection id bytes);
          loop u
    in
    match upload with
    | None -> command (fun () -> A.finish connection id)
    | Some u -> loop u
  in

  let rec head () =
    match A.next_event connection with
    | E.Informational (owner, _) when E.equal_id owner id -> head ()
    | E.Response (owner, response) when E.equal_id owner id -> response
    | E.Closed (Some error) -> raise (A.Error (A.Engine error))
    | _ -> raise (A.Error (A.Engine E.Invalid_command))
  in
  let response =
    Eio.Fiber.first
      (fun () ->
        send ();
        Eio.Fiber.await_cancel ())
      head
  in

  let received_trailers = ref None in
  let rec next () =
    match A.next_event connection with
    | E.Data (owner, data) when E.equal_id owner id -> Some data
    | E.Trailers (owner, headers) when E.equal_id owner id ->
        received_trailers := Some headers;
        next ()
    | E.Complete owner when E.equal_id owner id -> None
    | _ -> raise (A.Error (A.Engine E.Invalid_command))
  in
  let body =
    {
      next;
      open_ = true;
      busy = false;
      ended = false;
      trailers = received_trailers;
    }
  in
  Fun.protect
    ~finally:(fun () -> body.open_ <- false)
    (fun () ->
      let result = f response body in
      A.flush connection;
      reusable := body.ended && A.reusable connection;
      result)

let request pool ?headers ?meth ?upload ?(timeout = 30.) url f =
  Httpkit_client.check_timeout timeout;
  let endpoint =
    prepare ?headers ?meth ?upload ~keep_alive:pool.keep_alive url
  in
  if not pool.open_pool then invalid_arg "httpkit client: pool outside scope";
  if not (Httpkit_client.same_origin pool.origin endpoint) then
    invalid_arg "httpkit client: pool origin mismatch";
  if pool.busy_count >= pool.max_connections then raise Pool_exhausted;
  let engine = engine_ok (E.client ?limits:pool.limits ()) in
  claim_upload upload;
  Eio.Cancel.sub (fun cc ->
      let done_, finish = Eio.Promise.create () in
      pool.active <- (cc, done_) :: pool.active;
      pool.busy_count <- pool.busy_count + 1;
      Fun.protect
        ~finally:(fun () ->
          pool.busy_count <- pool.busy_count - 1;
          pool.active <- List.filter (fun (owner, _) -> owner != cc) pool.active;
          Eio.Promise.resolve finish ())
        (fun () ->
          pool.within timeout (fun () ->
              let acquire () =
                match pool.idle with
                | [] -> pool.connect ()
                | (t, released) :: rest ->
                    pool.idle <- rest;
                    if pool.now () -. released >= pool.idle_timeout then (
                      t.close ();
                      pool.connect ())
                    else t
              in
              let t = acquire () in
              let reusable = ref false in
              let proxy =
                { t with close = (fun () -> if not !reusable then t.close ()) }
              in
              match
                pool.drive proxy engine (fun c ->
                    exchange ?upload endpoint engine c reusable f)
              with
              | result ->
                  if !reusable && pool.keep_alive && pool.open_pool then
                    pool.idle <- (t, pool.now ()) :: pool.idle
                  else t.close ();
                  result
              | exception e ->
                  t.close ();
                  raise e)))

let scoped_pool ?(max_connections = 4) ?(idle_timeout = 30.) ?policy ?limits
    ~keep_alive ~net ~clock ~authenticator url f =
  if max_connections < 1 || max_connections > 1024 then
    invalid_arg "httpkit client: connection limit must be 1..1024";
  Httpkit_client.check_timeout idle_timeout;
  ignore (engine_ok (E.client ?limits ()));
  let origin = prepare ~keep_alive url in
  Eio.Switch.run (fun sw ->
      let pool =
        {
          origin;
          connect = (fun () -> connect ~sw ~net ~clock ~authenticator origin);
          now =
            (fun () ->
              Int64.to_float (Mtime.to_uint64_ns (Eio.Time.Mono.now clock))
              /. 1e9);
          within =
            (fun seconds f ->
              Eio.Time.Timeout.run_exn
                (Eio.Time.Timeout.seconds clock seconds)
                f);
          drive = (fun t e f -> A.with_connection ?policy ~clock t e f);
          limits;
          max_connections;
          idle_timeout;
          keep_alive;
          open_pool = true;
          busy_count = 0;
          idle = [];
          active = [];
        }
      in
      Fun.protect
        (fun () -> f pool)
        ~finally:(fun () ->
          Eio.Cancel.protect (fun () ->
              pool.open_pool <- false;
              let active = pool.active in
              List.iter (fun (cc, _) -> Eio.Cancel.cancel cc Exit) active;
              List.iter (fun (_, done_) -> Eio.Promise.await done_) active;
              let idle = pool.idle in
              pool.idle <- [];
              Eio.Fiber.all
                (List.map (fun (t, _) -> fun () -> t.A.close ()) idle))))

let with_pool ?max_connections ?idle_timeout ?policy ?limits ~authenticator ~net
    ~clock url f =
  scoped_pool ?max_connections ?idle_timeout ?policy ?limits ~keep_alive:true
    ~authenticator ~net ~clock url f

let with_response ?headers ?meth ?upload ?timeout ?policy ?limits ~authenticator
    ~net ~clock url f =
  scoped_pool ~max_connections:1 ?policy ?limits ~keep_alive:false
    ~authenticator ~net ~clock url (fun pool ->
      request pool ?headers ?meth ?upload ?timeout url f)
