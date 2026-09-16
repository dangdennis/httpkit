open Httpkit_core
open Lwt.Syntax
module A = Httpkit_transport_lwt
module E = Httpkit_engine

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

let settle p =
  Lwt.catch
    (fun () ->
      let* _ = p in
      Lwt.return_unit)
    (fun _ -> Lwt.return_unit)

let within seconds f =
  let work = Lwt.apply f () in
  let timer =
    let* () = Lwt_unix.sleep seconds in
    Lwt.fail Lwt_unix.Timeout
  in
  Lwt.finalize
    (fun () -> Lwt.choose [ work; timer ])
    (fun () ->
      Lwt.cancel work;
      Lwt.cancel timer;
      Lwt.join [ settle work; settle timer ])

let with_socket endpoint f =
  let* addresses =
    Lwt_unix.getaddrinfo endpoint.Httpkit_client.host
      (string_of_int endpoint.port)
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  in
  let rec connect last = function
    | [] -> Lwt.fail last
    | address :: rest -> (
        let fd =
          Lwt_unix.socket address.Unix.ai_family address.ai_socktype
            address.ai_protocol
        in
        let closed = ref false in
        let close () =
          if !closed then Lwt.return_unit
          else (
            closed := true;
            (* TLS may close the descriptor when our alert completes a peer's
               prior close_notify. The shared finalizer must not close twice. *)
            match Lwt_unix.state fd with
            | Lwt_unix.Closed -> Lwt.return_unit
            | Lwt_unix.Opened | Lwt_unix.Aborted _ -> Lwt_unix.close fd)
        in
        (* Only connection establishment tries another address; never replay HTTP. *)
        let* result =
          Lwt.catch
            (fun () ->
              let* () = Lwt_unix.connect fd address.ai_addr in
              Lwt.return (Ok ()))
            (fun e ->
              let* () = close () in
              match e with
              | Lwt.Canceled -> Lwt.fail e
              | _ -> Lwt.return (Error e))
        in
        match result with
        | Error e -> connect e rest
        | Ok () -> Lwt.finalize (fun () -> f fd close) close)
  in
  connect (Failure "httpkit client: no stream addresses") addresses

let with_response ?headers ?(timeout = 30.) ?policy ?limits ~authenticator url f
    =
  Lwt.apply
    (fun () ->
      Httpkit_client.check_timeout timeout;
      let endpoint =
        match Httpkit_client.prepare ?headers url with
        | Ok x -> x
        | Error e -> invalid_arg e
      in
      let engine = engine_ok (E.client ?limits ()) in
      within timeout (fun () ->
          with_socket endpoint (fun fd close ->
              let* transport =
                if not endpoint.tls then Lwt.return { (A.of_fd fd) with close }
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
                  let* tls = Tls_lwt.Unix.client_of_fd config ?host ?ip fd in
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
                          let* () =
                            Tls_lwt.Unix.write tls (String.sub src off len)
                          in
                          Lwt.return len);
                      close =
                        (fun () ->
                          Lwt.finalize
                            (fun () ->
                              Lwt.catch
                                (fun () ->
                                  within 1. (fun () ->
                                      Tls_lwt.Unix.shutdown tls `write))
                                (fun _ -> Lwt.return_unit))
                            close);
                    }
                  in
                  Lwt.return transport
              in
              A.with_connection ?policy transport engine (fun connection ->
                  let* id = A.submit_request connection endpoint.request in
                  let* () = A.finish connection id in
                  let rec head () =
                    let* event = A.next_event connection in
                    match event with
                    | E.Informational (owner, _) when E.equal_id owner id ->
                        head ()
                    | E.Response (owner, response) when E.equal_id owner id ->
                        Lwt.return response
                    | _ -> Lwt.fail (A.Error (A.Engine E.Invalid_command))
                  in
                  let* response = head () in
                  Httpkit_client.check_response ~tls:endpoint.tls response;
                  let received_trailers = ref None in
                  let rec next () =
                    let* event = A.next_event connection in
                    match event with
                    | E.Data (owner, data) when E.equal_id owner id ->
                        Lwt.return_some data
                    | E.Trailers (owner, headers) when E.equal_id owner id ->
                        received_trailers := Some headers;
                        next ()
                    | E.Complete owner when E.equal_id owner id ->
                        Lwt.return_none
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
                    (fun () -> f response body)
                    (fun () ->
                      body.open_ <- false;
                      Lwt.return_unit)))))
    ()
