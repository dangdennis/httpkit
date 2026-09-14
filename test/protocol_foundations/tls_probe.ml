open Support

let cert =
  lazy (ok (X509.Certificate.decode_pem (read "fixtures/localhost.pem")))

let key =
  lazy (ok (X509.Private_key.decode_pem (read "fixtures/localhost.key")))

let handshake ~host ~trusted ~chunk =
  let time () = Ptime.of_date_time ((2026, 9, 14), ((0, 0, 0), 0)) in
  let authenticator =
    X509.Authenticator.chain_of_trust ~time
      (if trusted then [ Lazy.force cert ] else [])
  in
  let client_config =
    ok
      (Tls.Config.client ~authenticator
         ~peer_name:(Domain_name.host_exn (Domain_name.of_string_exn host))
         ~alpn_protocols:[ "http/1.1" ] ())
  in
  let server_config =
    ok
      (Tls.Config.server
         ~certificates:(`Single ([ Lazy.force cert ], Lazy.force key))
         ~alpn_protocols:[ "http/1.1" ] ())
  in
  let client, hello = Tls.Engine.client client_config in
  let client = ref client and server = ref (Tls.Engine.server server_config) in
  let queue = Queue.create () in
  Queue.add (`Server, hello) queue;
  let failure = ref false and steps = ref 0 in
  while (not (Queue.is_empty queue)) && not !failure do
    incr steps;
    require (!steps < 1000) "TLS handshake stalled";
    let side, bytes = Queue.take queue in
    let state, other =
      match side with
      | `Client -> (client, `Server)
      | `Server -> (server, `Client)
    in
    fragments chunk bytes (fun fragment ->
        if not !failure then
          match Tls.Engine.handle_tls !state fragment with
          | Error _ -> failure := true
          | Ok (next, eof, `Response reply, `Data data) ->
              require
                (eof = None && data = None)
                "Unexpected handshake data/EOF";
              state := next;
              Option.iter (fun wire -> Queue.add (other, wire) queue) reply)
  done;
  if !failure then Error ()
  else (
    require
      ((not (Tls.Engine.handshake_in_progress !client))
      && not (Tls.Engine.handshake_in_progress !server))
      "TLS incomplete handshake";
    let epoch =
      match Tls.Engine.epoch !client with
      | Ok x -> x
      | Error () -> failwith "TLS epoch"
    in
    require (epoch.alpn_protocol = Some "http/1.1") "TLS ALPN";
    Ok (client, server))

let run () =
  List.iter
    (fun chunk ->
      let client, server =
        match handshake ~host:"localhost" ~trusted:true ~chunk with
        | Ok x -> x
        | Error () -> failwith "trusted TLS handshake failed"
      in
      let next, wire =
        match Tls.Engine.send_application_data !client [ "hello" ] with
        | Some x -> x
        | None -> failwith "TLS write unavailable"
      in
      client := next;
      let clear = Buffer.create 16 in
      fragments chunk wire (fun bytes ->
          match Tls.Engine.handle_tls !server bytes with
          | Ok (next, None, `Response _, `Data data) ->
              server := next;
              Option.iter (Buffer.add_string clear) data
          | _ -> failwith "TLS data failed");
      require (Buffer.contents clear = "hello") "TLS application data";
      let _, close = Tls.Engine.send_close_notify !client in
      match Tls.Engine.handle_tls !server close with
      | Ok (_, Some `Eof, _, _) -> ()
      | _ -> failwith "TLS close_notify")
    [ 1; 17; 16384 ];
  require
    (Result.is_error (handshake ~host:"wrong.example" ~trusted:true ~chunk:17))
    "TLS wrong host accepted";
  require
    (Result.is_error (handshake ~host:"localhost" ~trusted:false ~chunk:17))
    "TLS unknown CA accepted";
  `Assoc
    [
      ("status", `String "PASS");
      ("alpn", `String "http/1.1");
      ("negative_controls", `Int 2);
      ("production_ready", `Bool false);
    ]
