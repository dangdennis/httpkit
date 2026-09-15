module D = Httpkit_db_eio
module S = Httpkit_session_eio
module A = Httpkit_eio
module W = Httpkit

let check label b = if not b then failwith label

let http env handler meth path headers =
  let wire =
    meth ^ " " ^ path
    ^ " HTTP/1.1\r\n\
       Host: app.example\r\n\
       Connection: close\r\n\
       Content-Length: 0\r\n"
    ^ String.concat "" (List.map (fun header -> header ^ "\r\n") headers)
    ^ "\r\n"
  in
  let offset = ref 0 and closes = ref 0 and errors = ref [] in
  let output = Buffer.create 256 in
  let stop, wake = Eio.Promise.create () in
  let transport : Httpkit_transport_eio.transport =
    {
      read =
        (fun bytes off len ->
          if !offset = String.length wire then Eio.Fiber.await_cancel ();
          let count = min len (String.length wire - !offset) in
          Bytes.blit_string wire !offset bytes off count;
          offset := !offset + count;
          count);
      write =
        (fun bytes off len ->
          Buffer.add_substring output bytes off len;
          len);
      close =
        (fun () ->
          incr closes;
          Eio.Promise.resolve wake ());
    }
  in
  let accepted = ref false in
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () ->
      A.serve ~max_connections:1
        ~clock:(Eio.Stdenv.mono_clock env)
        ~stop ~random:Mirage_crypto_rng.generate
        ~accept:(fun () ->
          if !accepted then Eio.Fiber.await_cancel ();
          accepted := true;
          (transport, "local"))
        ~on_error:(fun exn -> errors := exn :: !errors)
        handler);
  check "session HTTP closes exactly once" (!closes = 1 && !errors = []);
  Buffer.contents output

let http_sessions env store shared =
  let session = S.issue store ~subject:"browser" "profile" in
  let calls = ref 0 in
  let protected =
    S.require shared (fun s _ ->
        incr calls;
        A.reply (W.Reply.text (S.subject s ^ ":" ^ S.value s)))
  in
  let handler request =
    match
      Httpkit_core.Target.to_string
        (Httpkit_core.Request.target (A.head request))
    with
    | "/attach" -> S.attach store session (A.reply (W.Reply.text "attached"))
    | "/logout" ->
        S.protect_csrf shared ~origins:[ "https://app.example" ]
          (fun request ->
            S.logout shared request (A.reply (W.Reply.text "logged out")))
          request
    | _ ->
        S.protect_csrf shared ~origins:[ "https://app.example" ] protected
          request
  in
  let cookie = "Cookie: __Host-httpkit=" ^ S.token session in
  let origin = "Origin: https://app.example" in
  let csrf = "X-CSRF-Token: " ^ S.csrf session in
  let status response code =
    check "SQL-session HTTP status"
      (String.starts_with
         ~prefix:("HTTP/1.1 " ^ string_of_int code ^ " ")
         response)
  in
  let attached = http env handler "GET" "/attach" [] in
  status attached 200;
  check "SQL session cookie attached"
    (List.exists
       (String.starts_with
          ~prefix:("set-cookie: __Host-httpkit=" ^ S.token session ^ ";"))
       (String.split_on_char '\n' attached));
  status (http env handler "GET" "/private" []) 401;
  status (http env handler "GET" "/private" [ "Cookie: malformed" ]) 401;
  status (http env handler "GET" "/private" [ cookie; cookie ]) 401;
  let private_response = http env handler "GET" "/private" [ cookie ] in
  status private_response 200;
  check "shared HTTP session identity"
    (String.ends_with ~suffix:"browser:profile" private_response);
  status (http env handler "POST" "/private" [ cookie; origin ]) 403;
  status
    (http env handler "POST" "/private"
       [ cookie; origin; "X-CSRF-Token: wrong" ])
    403;
  status
    (http env handler "POST" "/private"
       [ cookie; csrf; "Origin: https://attacker.example" ])
    403;
  status (http env handler "POST" "/private" [ cookie; origin; csrf ]) 200;
  check "rejected requests never reach protected handler" (!calls = 2);
  let logged_out = http env handler "POST" "/logout" [ cookie; origin; csrf ] in
  status logged_out 200;
  check "logout clears cookie"
    (List.exists
       (String.starts_with ~prefix:"set-cookie: __Host-httpkit=;")
       (String.split_on_char '\n' logged_out));
  check "logout revokes across stores" (S.find store (S.token session) = None);
  status (http env handler "GET" "/private" [ cookie ]) 401

module Corrupt = struct
  open Caqti.Templater

  let update =
    static
      T.(t4 string string string string -->. unit)
      "UPDATE httpkit_sessions SET subject=?, value=?, csrf=? WHERE namespace=?"
end

let stored_constraints db store ~sqlite =
  let session = S.issue store ~subject:"valid" "valid" in
  let cases =
    [
      ("", "valid", S.csrf session);
      ("valid", String.make 8193 'x', S.csrf session);
      ("valid", "valid", "short");
    ]
    @
    if sqlite then
      [
        ("bad\000subject", "valid", S.csrf session);
        ("bad\255subject", "valid", S.csrf session);
        ("valid", "bad\000value", S.csrf session);
        ("valid", "bad\255value", S.csrf session);
      ]
    else []
  in
  List.iter
    (fun (subject, value, csrf) ->
      D.use db (fun (module C) ->
          Caqti_eio.or_fail
            (C.exec Corrupt.update (subject, value, csrf, "corrupt")));
      match S.find store (S.token session) with
      | _ -> failwith "stored session violated issuance constraints"
      | exception Failure message ->
          check "corrupt row fails closed" (message = "invalid stored session"))
    cases;
  D.use db (fun (module C) ->
      Caqti_eio.or_fail
        (C.exec Corrupt.update ("valid", "restored", S.csrf session, "corrupt")));
  check "corrupt read does not poison database lease"
    (S.value (Option.get (S.find store (S.token session))) = "restored")

let configuration db =
  let invalid f =
    match f () with
    | _ -> failwith "invalid SQL session configuration accepted"
    | exception Invalid_argument _ -> ()
  in
  let create ?(namespace = "policy") ?(ttl = 60) ?(max_payload = 8192)
      ?(now = fun () -> 1000.) ?(random = fun n -> Mirage_crypto_rng.generate n)
      () =
    S.create ~namespace ~ttl ~max_payload ~now ~random db
  in
  List.iter
    (fun namespace -> invalid (fun () -> create ~namespace ()))
    [ ""; String.make 129 'x'; "bad\000name" ];
  List.iter (fun ttl -> invalid (fun () -> create ~ttl ())) [ 0; 2592001 ];
  List.iter
    (fun max_payload -> invalid (fun () -> create ~max_payload ()))
    [ -1; 1048577 ];
  let store = create () in
  List.iter
    (fun subject -> invalid (fun () -> S.issue store ~subject "value"))
    [ ""; String.make 257 'x'; "bad\000subject"; "bad\255subject" ];
  List.iter
    (fun value -> invalid (fun () -> S.issue store ~subject:"valid" value))
    [ String.make 8193 'x'; "bad\000value"; "bad\255value" ];
  List.iter
    (fun time ->
      invalid (fun () ->
          S.issue (create ~now:(fun () -> time) ()) ~subject:"valid" "value"))
    [ Float.nan; Float.infinity; -1.; 253402300800. ];
  invalid (fun () ->
      S.issue (create ~random:(fun _ -> "short") ()) ~subject:"valid" "value");
  List.iter (fun limit -> invalid (fun () -> S.prune ~limit store)) [ 0; 10001 ];
  let generated = ref 0 in
  let colliding =
    create ~namespace:"collision"
      ~random:(fun n ->
        incr generated;
        String.make n 'x')
      ()
  in
  let original = S.issue colliding ~subject:"first" "original" in
  let collision f =
    match f () with
    | _ -> failwith "entropy collision accepted"
    | exception Failure message ->
        check "explicit collision failure"
          (message = "session entropy collision")
  in
  collision (fun () -> S.issue colliding ~subject:"second" "replacement");
  check "issuance retry is bounded" (!generated = 8);
  collision (fun () ->
      S.rotate colliding (S.token original) ~subject:"second" "replacement");
  check "collision preserves existing identity"
    (S.subject (Option.get (S.find colliding (S.token original))) = "first");
  check "invalid rotation token bypasses entropy"
    (S.rotate
       (create ~random:(fun _ -> failwith "invalid token used entropy") ())
       "short" ~subject:"valid" "value"
    = None)

let () =
  Mirage_crypto_rng_unix.use_default ();
  let temporary =
    if Array.length Sys.argv = 1 then
      Some (Filename.temp_file "httpkit-session" ".sqlite")
    else None
  in
  let uri =
    Uri.of_string
      (match temporary with
      | Some path -> "sqlite3:" ^ path
      | None -> Sys.argv.(1))
  in
  Fun.protect
    ~finally:(fun () -> Option.iter Sys.remove temporary)
    (fun () ->
      Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
              let db =
                D.create ~max_connections:4 ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  uri
              in
              D.migrate db [ S.migration ~version:1 ];
              configuration db;
              let now = ref 1000. in
              let store namespace =
                S.create ~namespace ~ttl:60
                  ~now:(fun () -> !now)
                  ~random:Mirage_crypto_rng.generate db
              in
              let a = store "app"
              and b = store "app"
              and other = store "other" in
              stored_constraints db (store "corrupt")
                ~sqlite:(Uri.scheme uri = Some "sqlite3");
              http_sessions env a b;
              let session = S.issue a ~subject:"user" "payload" in
              check "shared store"
                (S.value (Option.get (S.find b (S.token session))) = "payload");
              check "namespace isolation" (S.find other (S.token session) = None);
              let results = Array.make 2 None in
              Eio.Fiber.all
                (List.init 2 (fun i () ->
                     results.(i) <-
                       S.rotate
                         (if i = 0 then a else b)
                         (S.token session) ~subject:"user" "rotated"));
              check "single rotation winner"
                (Array.fold_left
                   (fun n x -> if Option.is_some x then n + 1 else n)
                   0 results
                = 1);
              check "old token revoked" (S.find a (S.token session) = None);
              let winner =
                Option.get
                  (if results.(0) = None then results.(1) else results.(0))
              in
              check "csrf rotated" (S.csrf session <> S.csrf winner);
              S.revoke b (S.token winner);
              check "revocation" (S.find a (S.token winner) = None);
              let x = S.issue a ~subject:"user" "one"
              and y = S.issue b ~subject:"user" "two" in
              S.revoke_subject a "user";
              check "logout all"
                (S.find b (S.token x) = None && S.find a (S.token y) = None);
              let x = S.issue a ~subject:"expires" "payload" in
              now := 1060.;
              check "absolute expiry" (S.find b (S.token x) = None);
              S.prune ~limit:1 a;
              D.close db;
              let reopened =
                D.create ~sw ~stdenv:(env :> Caqti_eio.stdenv) uri
              in
              let persisted =
                S.create ~namespace:"app" ~ttl:60
                  ~now:(fun () -> !now)
                  ~random:Mirage_crypto_rng.generate reopened
              in
              let saved = S.issue persisted ~subject:"persistent" "durable" in
              D.close reopened;
              let db = D.create ~sw ~stdenv:(env :> Caqti_eio.stdenv) uri in
              let again =
                S.create ~namespace:"app" ~ttl:60
                  ~now:(fun () -> !now)
                  ~random:Mirage_crypto_rng.generate db
              in
              check "reopen persistence"
                (S.value (Option.get (S.find again (S.token saved))) = "durable");
              D.close db)));
  print_endline
    "PASS durable shared sessions, atomic rotation, revocation and persistence"
