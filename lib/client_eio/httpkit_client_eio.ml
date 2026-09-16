open Httpkit_core
module A = Httpkit_transport_eio
module E = Httpkit_engine

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

let with_response ?headers ?(timeout = 30.) ?policy ?limits ~authenticator ~net
    ~clock url f =
  Httpkit_client.check_timeout timeout;
  let endpoint =
    match Httpkit_client.prepare ?headers url with
    | Ok x -> x
    | Error e -> invalid_arg e
  in
  let engine = engine_ok (E.client ?limits ()) in
  Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock timeout) (fun () ->
      Eio.Net.with_tcp_connect net ~host:endpoint.host
        ~service:(string_of_int endpoint.port) (fun raw ->
          let transport =
            if not endpoint.tls then A.of_flow raw
            else
              let config =
                match
                  Tls.Config.client ~authenticator
                    ~alpn_protocols:[ "http/1.1" ] ()
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
              let flow = Tls_eio.client_of_flow config ?host ?ip raw in
              let transport = A.of_flow flow in
              {
                transport with
                close =
                  (fun () ->
                    Fun.protect ~finally:transport.close (fun () ->
                        (* Teardown must not wait indefinitely for a TLS write. *)
                        try
                          Eio.Time.Timeout.run_exn
                            (Eio.Time.Timeout.seconds clock 1.) (fun () ->
                              Eio.Flow.shutdown flow `Send)
                        with _ -> ()));
              }
          in
          A.with_connection ?policy ~clock transport engine (fun connection ->
              let id = A.submit_request connection endpoint.request in
              A.finish connection id;
              let rec head () =
                match A.next_event connection with
                | E.Informational (owner, _) when E.equal_id owner id -> head ()
                | E.Response (owner, response) when E.equal_id owner id ->
                    response
                | _ -> raise (A.Error (A.Engine E.Invalid_command))
              in
              let response = head () in
              Httpkit_client.check_response ~tls:endpoint.tls response;
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
                (fun () -> f response body))))
