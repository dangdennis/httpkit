module D = Httpkit_db_eio
module S = Httpkit_session_eio

let check label b = if not b then failwith label

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
              let now = ref 1000. in
              let store namespace =
                S.create ~namespace ~ttl:60
                  ~now:(fun () -> !now)
                  ~random:Mirage_crypto_rng.generate db
              in
              let a = store "app"
              and b = store "app"
              and other = store "other" in
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
