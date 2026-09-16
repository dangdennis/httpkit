open Httpkit_core
open Lwt.Syntax
module A = Httpkit_transport_lwt
module E = Httpkit_engine

type upload = {
  length : int64 option;
  produce : unit -> string option Lwt.t;
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
  next : unit -> string option Lwt.t;
  mutable open_ : bool;
  mutable busy : bool;
  mutable ended : bool;
  trailers : Headers.t option ref;
}

let read body =
  if (not body.open_) || body.busy then
    Lwt.fail
      (Invalid_argument "httpkit client: body outside scope or concurrent read")
  else if body.ended then Lwt.return_none
  else (
    body.busy <- true;
    Lwt.finalize
      (fun () ->
        let* chunk = body.next () in
        if chunk = None then body.ended <- true;
        Lwt.return chunk)
      (fun () ->
        body.busy <- false;
        Lwt.return_unit))

let trailers body =
  if body.ended then Some (Option.value !(body.trailers) ~default:Headers.empty)
  else None

let engine_ok = function Ok x -> x | Error e -> raise (A.Error (A.Engine e))
let settle = Network.settle
let within = Network.within

exception Pool_exhausted

type pool = {
  origin : Httpkit_client.endpoint;
  connect : unit -> A.transport Lwt.t;
  policy : E.Timeout.policy option;
  limits : Httpkit_http1.limits option;
  max_connections : int;
  idle_timeout : float;
  keep_alive : bool;
  mutable open_pool : bool;
  mutable busy_count : int;
  mutable idle : (A.transport * float) list;
  mutable active : unit Lwt.t list;
}

let connect ~authenticator (endpoint : Httpkit_client.endpoint) =
  let* fd, close = Network.socket endpoint in
  Lwt.catch
    (fun () ->
      let* transport =
        if not endpoint.tls then Lwt.return { (A.of_fd fd) with close }
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
          (* The channel's raw EOF is an error. Only the upstream TLS
                     engine may turn a verified closure alert into read = 0. *)
          let ic =
            Lwt_io.make ~mode:Lwt_io.input
              ~close:(fun () -> Lwt.return_unit)
              (fun bytes off len ->
                let* n = Lwt_bytes.read fd bytes off len in
                if n = 0 then Lwt.fail Httpkit_client.Tls_truncated
                else Lwt.return n)
          in
          let oc =
            Lwt_io.make ~mode:Lwt_io.output
              ~close:(fun () -> Lwt.return_unit)
              (fun bytes off len -> Lwt_bytes.write fd bytes off len)
          in
          let close () =
            Lwt.finalize close (fun () ->
                Lwt.join [ settle (Lwt_io.abort ic); settle (Lwt_io.abort oc) ])
          in
          let* tls =
            Lwt.catch
              (fun () ->
                Tls_lwt.Unix.client_of_channels config ?host ?ip (ic, oc))
              (fun e ->
                let* () = close () in
                Lwt.fail e)
          in

          let transport : A.transport =
            {
              read =
                (fun dst off len ->
                  let scratch = Bytes.create len in
                  let* n = Tls_lwt.Unix.read tls scratch in
                  Bytes.blit scratch 0 dst off n;
                  Lwt.return n);
              write =
                (fun src off len ->
                  let* () = Tls_lwt.Unix.write tls (String.sub src off len) in
                  let* () = Lwt_io.flush oc in
                  Lwt.return len);
              close =
                (fun () ->
                  Lwt.finalize
                    (fun () ->
                      Lwt.catch
                        (fun () ->
                          within 1. (fun () ->
                              let* () = Tls_lwt.Unix.shutdown tls `write in
                              if Lwt_io.is_closed oc then Lwt.return_unit
                              else Lwt_io.flush oc))
                        (fun _ -> Lwt.return_unit))
                    close);
            }
          in
          Lwt.return transport
      in
      let closed = ref false in
      Lwt.return
        {
          transport with
          close =
            (fun () ->
              if !closed then Lwt.return_unit
              else (
                closed := true;
                transport.close ()));
        })
    (fun e ->
      let* () = close () in
      Lwt.fail e)

let prepare ?headers ?meth ?upload ~keep_alive url =
  match
    Httpkit_client.prepare ?headers ?meth ~body:(framing upload) ~keep_alive url
  with
  | Ok x -> x
  | Error e -> invalid_arg e

let exchange ?upload (endpoint : Httpkit_client.endpoint) engine connection
    reusable f =
  let* id = A.submit_request connection endpoint.request in
  let command f =
    Lwt.catch f (function
      | A.Error (A.Engine E.Invalid_command) when E.upload_aborted engine id ->
          (* Wait for the response owner to cancel and join the producer. *)
          fst (Lwt.task ())
      | e -> Lwt.fail e)
  in
  let send () =
    let rec loop u =
      let* chunk = u.produce () in
      match chunk with
      | None -> command (fun () -> A.finish connection id)
      | Some bytes ->
          if bytes = "" || String.length bytes > 65536 then
            invalid_arg "httpkit client: upload chunks must be 1..65536 bytes";
          let* () = command (fun () -> A.send connection id bytes) in
          loop u
    in
    match upload with
    | None -> command (fun () -> A.finish connection id)
    | Some u -> loop u
  in

  let rec head () =
    let* event = A.next_event connection in
    match event with
    | E.Informational (owner, _) when E.equal_id owner id -> head ()
    | E.Response (owner, response) when E.equal_id owner id ->
        Lwt.return response
    | E.Closed (Some error) -> Lwt.fail (A.Error (A.Engine error))
    | _ -> Lwt.fail (A.Error (A.Engine E.Invalid_command))
  in
  let sending =
    let* () = send () in
    fst (Lwt.task ())
  in
  let receiving = head () in
  let* response =
    Lwt.finalize
      (fun () -> Lwt.choose [ sending; receiving ])
      (fun () ->
        Lwt.cancel sending;
        Lwt.cancel receiving;
        Lwt.join [ settle sending; settle receiving ])
  in

  let received_trailers = ref None in
  let rec next () =
    let* event = A.next_event connection in
    match event with
    | E.Data (owner, data) when E.equal_id owner id -> Lwt.return_some data
    | E.Trailers (owner, headers) when E.equal_id owner id ->
        received_trailers := Some headers;
        next ()
    | E.Complete owner when E.equal_id owner id -> Lwt.return_none
    | _ -> Lwt.fail (A.Error (A.Engine E.Invalid_command))
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
  Lwt.finalize
    (fun () ->
      let* result = f response body in
      let* () = A.flush connection in
      reusable := body.ended && A.reusable connection;
      Lwt.return result)
    (fun () ->
      body.open_ <- false;
      Lwt.return_unit)

let request pool ?headers ?meth ?upload ?(timeout = 30.) url f =
  Lwt.apply
    (fun () ->
      Httpkit_client.check_timeout timeout;
      let endpoint =
        prepare ?headers ?meth ?upload ~keep_alive:pool.keep_alive url
      in
      if not pool.open_pool then
        invalid_arg "httpkit client: pool outside scope";
      if not (Httpkit_client.same_origin pool.origin endpoint) then
        invalid_arg "httpkit client: pool origin mismatch";
      if pool.busy_count >= pool.max_connections then raise Pool_exhausted;
      let engine = engine_ok (E.client ?limits:pool.limits ()) in
      claim_upload upload;
      pool.busy_count <- pool.busy_count + 1;
      let work =
        Lwt.finalize
          (fun () ->
            within timeout (fun () ->
                let acquire () =
                  match pool.idle with
                  | [] -> pool.connect ()
                  | (t, released) :: rest ->
                      pool.idle <- rest;
                      if
                        A.monotonic_clock.now () -. released
                        >= pool.idle_timeout
                      then
                        let* () = t.close () in
                        pool.connect ()
                      else Lwt.return t
                in
                let* t = acquire () in
                let reusable = ref false in
                let proxy =
                  {
                    t with
                    close =
                      (fun () ->
                        if !reusable then Lwt.return_unit else t.close ());
                  }
                in
                Lwt.catch
                  (fun () ->
                    let* result =
                      A.with_connection ?policy:pool.policy proxy engine
                        (fun c -> exchange ?upload endpoint engine c reusable f)
                    in
                    let* () =
                      if !reusable && pool.keep_alive && pool.open_pool then (
                        pool.idle <- (t, A.monotonic_clock.now ()) :: pool.idle;
                        Lwt.return_unit)
                      else t.close ()
                    in
                    Lwt.return result)
                  (fun e ->
                    let* () = t.close () in
                    Lwt.fail e)))
          (fun () ->
            pool.busy_count <- pool.busy_count - 1;
            Lwt.return_unit)
      in
      let joined = settle work in
      pool.active <- joined :: pool.active;
      Lwt.on_any joined
        (fun () ->
          pool.active <- List.filter (fun p -> p != joined) pool.active)
        (fun _ -> pool.active <- List.filter (fun p -> p != joined) pool.active);
      work)
    ()

let scoped_pool ?(max_connections = 4) ?(idle_timeout = 30.) ?policy ?limits
    ~keep_alive ~authenticator url f =
  Lwt.apply
    (fun () ->
      if max_connections < 1 || max_connections > 1024 then
        invalid_arg "httpkit client: connection limit must be 1..1024";
      Httpkit_client.check_timeout idle_timeout;
      ignore (engine_ok (E.client ?limits ()));
      let origin = prepare ~keep_alive url in
      let pool =
        {
          origin;
          connect = (fun () -> connect ~authenticator origin);
          policy;
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
      Lwt.finalize
        (fun () -> f pool)
        (fun () ->
          pool.open_pool <- false;
          (* A callback may wake the pool owner synchronously before its pending
         promise has been linked into the request. Defer cancellation one turn
         so that cancellation reaches that continuation and its finalizers. *)
          let* () = Lwt.pause () in
          let active = pool.active in
          List.iter Lwt.cancel active;
          let* () = Lwt.join (List.map settle active) in
          let idle = pool.idle in
          pool.idle <- [];
          Lwt.join (List.map (fun (t, _) -> Lwt.apply t.A.close ()) idle)))
    ()

let with_pool ?max_connections ?idle_timeout ?policy ?limits ~authenticator url
    f =
  scoped_pool ?max_connections ?idle_timeout ?policy ?limits ~keep_alive:true
    ~authenticator url f

let with_response ?headers ?meth ?upload ?timeout ?policy ?limits ~authenticator
    url f =
  scoped_pool ~max_connections:1 ?policy ?limits ~keep_alive:false
    ~authenticator url (fun pool ->
      request pool ?headers ?meth ?upload ?timeout url f)
