open Lwt.Syntax

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

let socket ?(resolve = Lwt_unix.getaddrinfo) ?(dial = Lwt_unix.connect) endpoint
    =
  let* addresses =
    resolve endpoint.Httpkit_client.host
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
              let* () = dial fd address.ai_addr in
              Lwt.return (Ok ()))
            (fun e ->
              let* () = close () in
              match e with
              | Unix.Unix_error _ -> Lwt.return (Error e)
              | _ -> Lwt.fail e)
        in
        match result with
        | Error e -> connect e rest
        | Ok () -> Lwt.return (fd, close))
  in
  connect (Failure "httpkit client: no stream addresses") addresses
