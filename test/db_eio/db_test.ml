module D = Httpkit_db_eio

module Queries = struct
  open Caqti.Templater

  let insert = static T.(int -->. unit) "INSERT INTO items(id) VALUES (?)"
  let count = static T.(unit -->! int) "SELECT COUNT(*) FROM items"
end

let ok = Caqti_eio.or_fail
let check message test = if not test then failwith message

let migration =
  {
    D.version = 1;
    postgresql = [ "CREATE TABLE items(id INTEGER PRIMARY KEY)" ];
    sqlite = [ "CREATE TABLE items(id INTEGER PRIMARY KEY)" ];
  }

exception Abort

let () =
  let temporary =
    if Array.length Sys.argv = 1 then
      Some (Filename.temp_file "httpkit-db-" ".sqlite")
    else None
  in
  let uri =
    match temporary with
    | Some path -> Uri.of_string ("sqlite3:" ^ path)
    | None -> Uri.of_string Sys.argv.(1)
  in
  Fun.protect
    ~finally:(fun () -> Option.iter Sys.remove temporary)
    (fun () ->
      Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
              let invalid f =
                check "invalid configuration rejected"
                  (try
                     f ();
                     false
                   with Invalid_argument _ -> true)
              in
              List.iter
                (fun f -> invalid f)
                [
                  (fun () ->
                    ignore
                      (D.create ~max_connections:0 ~sw
                         ~stdenv:(env :> Caqti_eio.stdenv)
                         uri));
                  (fun () ->
                    ignore
                      (D.create ~max_waiters:(-1) ~sw
                         ~stdenv:(env :> Caqti_eio.stdenv)
                         uri));
                  (fun () ->
                    ignore
                      (D.create ~statement_timeout:nan ~sw
                         ~stdenv:(env :> Caqti_eio.stdenv)
                         uri));
                  (fun () ->
                    ignore
                      (D.create ~statement_timeout:0. ~sw
                         ~stdenv:(env :> Caqti_eio.stdenv)
                         uri));
                  (fun () ->
                    ignore
                      (D.create ~statement_timeout:2147484. ~sw
                         ~stdenv:(env :> Caqti_eio.stdenv)
                         uri));
                  (fun () ->
                    ignore
                      (D.create ~sw
                         ~stdenv:(env :> Caqti_eio.stdenv)
                         (Uri.of_string "sqlite3::memory:")));
                  (fun () ->
                    ignore
                      (D.create ~sw
                         ~stdenv:(env :> Caqti_eio.stdenv)
                         (Uri.of_string "mysql://localhost")));
                ];
              let db =
                D.create ~max_connections:2 ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  uri
              in
              List.iter
                (fun migrations -> invalid (fun () -> D.migrate db migrations))
                [
                  [ { migration with version = 0 } ];
                  [ migration; migration ];
                  [ { migration with postgresql = []; sqlite = [] } ];
                  [
                    {
                      migration with
                      postgresql = List.init 1001 (fun _ -> "SELECT 1");
                      sqlite = List.init 1001 (fun _ -> "SELECT 1");
                    };
                  ];
                ];
              Eio.Fiber.both
                (fun () -> D.migrate db [ migration ])
                (fun () -> D.migrate db [ migration ]);
              D.migrate db [ migration ];
              D.transaction db (fun (module C : Caqti_eio.CONNECTION) ->
                  ok (C.exec Queries.insert 1));
              (try
                 D.transaction db (fun (module C : Caqti_eio.CONNECTION) ->
                     ok (C.exec Queries.insert 2);
                     raise Abort)
               with Abort -> ());
              let count () =
                D.use db (fun (module C : Caqti_eio.CONNECTION) ->
                    ok (C.find Queries.count ()))
              in
              check "exception rollback" (count () = 1);
              let inserted, notify = Eio.Promise.create () in
              Eio.Fiber.first
                (fun () ->
                  D.transaction db (fun (module C : Caqti_eio.CONNECTION) ->
                      ok (C.exec Queries.insert 3);
                      Eio.Promise.resolve notify ();
                      Eio.Fiber.await_cancel ()))
                (fun () -> Eio.Promise.await inserted);
              check "cancellation rollback" (count () = 1);
              let corrupt =
                {
                  migration with
                  postgresql = [ "SELECT 1" ];
                  sqlite = [ "SELECT 1" ];
                }
              in
              check "migration checksum"
                (try
                   D.migrate db [ corrupt ];
                   false
                 with Invalid_argument _ -> true);
              let broken =
                {
                  D.version = 2;
                  postgresql =
                    [ "CREATE TABLE rolled_back(id INTEGER)"; "NOT SQL" ];
                  sqlite = [ "CREATE TABLE rolled_back(id INTEGER)"; "NOT SQL" ];
                }
              in
              check "failed migration"
                (try
                   D.migrate db [ migration; broken ];
                   false
                 with Caqti.Error.Exn _ -> true);
              let fixed =
                {
                  broken with
                  postgresql = [ "CREATE TABLE rolled_back(id INTEGER)" ];
                  sqlite = [ "CREATE TABLE rolled_back(id INTEGER)" ];
                }
              in
              D.migrate db [ migration; fixed ];
              check "pool bound" (D.size db <= 2);
              D.close db;
              check "closed pool"
                (try
                   ignore (count ());
                   false
                 with Invalid_argument _ -> true);
              let limited =
                D.create ~max_connections:1 ~max_waiters:0 ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  uri
              in
              D.use limited (fun _ ->
                  check "waiter bound"
                    (try
                       D.use limited ignore;
                       false
                     with D.Busy -> true));
              D.close limited;
              let queued =
                D.create ~max_connections:1 ~max_waiters:1 ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  uri
              in
              D.use queued (fun _ ->
                  for _ = 1 to 2 do
                    check "cancelled waiter releases capacity"
                      (try
                         Eio.Time.Timeout.run_exn
                           (Eio.Time.Timeout.seconds
                              (Eio.Stdenv.mono_clock env)
                              0.02)
                           (fun () -> D.use queued ignore);
                         false
                       with Eio.Time.Timeout -> true)
                  done);
              D.use queued (fun (module C : Caqti_eio.CONNECTION) ->
                  C.disconnect ());
              D.use queued (fun (module C : Caqti_eio.CONNECTION) ->
                  check "disconnected resource replaced"
                    (ok (C.find Queries.count ()) = 1));
              let held, held_notify = Eio.Promise.create ()
              and release, release_notify = Eio.Promise.create () in
              Eio.Fiber.both
                (fun () ->
                  D.use queued (fun _ ->
                      Eio.Promise.resolve held_notify ();
                      Eio.Promise.await release))
                (fun () ->
                  Eio.Promise.await held;
                  Eio.Fiber.both
                    (fun () -> D.close queued)
                    (fun () ->
                      Eio.Fiber.yield ();
                      Eio.Promise.resolve release_notify ()));
              check "close drains outstanding checkout" (D.size queued = 0);
              D.close queued;
              let draining =
                D.create ~max_connections:1 ~max_waiters:0 ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  uri
              in
              let entered, notify_entered = Eio.Promise.create ()
              and cleaning, notify_cleaning = Eio.Promise.create ()
              and release, notify_release = Eio.Promise.create () in
              let finalized = ref false
              and retired = ref false
              and closed = ref false in
              Eio.Fiber.both
                (fun () ->
                  Eio.Fiber.first
                    (fun () ->
                      D.transaction draining
                        (fun (module C : Caqti_eio.CONNECTION) ->
                          ok (C.exec Queries.insert 4);
                          Fun.protect
                            ~finally:(fun () ->
                              Eio.Cancel.protect (fun () ->
                                  Eio.Promise.resolve notify_cleaning ();
                                  Eio.Promise.await release;
                                  check "lease remains usable during cleanup"
                                    (ok (C.find Queries.count ()) = 2);
                                  finalized := true))
                            (fun () ->
                              Eio.Promise.resolve notify_entered ();
                              Eio.Fiber.await_cancel ())))
                    (fun () -> Eio.Promise.await entered);
                  retired := true)
                (fun () ->
                  Eio.Promise.await cleaning;
                  check "cleanup still owns the only lease"
                    (try
                       D.use draining ignore;
                       false
                     with D.Busy -> true);
                  Eio.Fiber.both
                    (fun () ->
                      D.close draining;
                      closed := true)
                    (fun () ->
                      Eio.Fiber.yield ();
                      check "close waits for callback finalizer and rollback"
                        ((not !closed) && (not !retired) && not !finalized);
                      invalid (fun () -> D.use draining ignore);
                      Eio.Promise.resolve notify_release ()));
              check "cancellation joins transaction cleanup"
                (!finalized && !retired && !closed && D.size draining = 0);
              let verifier =
                D.create ~max_connections:1 ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  uri
              in
              D.use verifier (fun (module C : Caqti_eio.CONNECTION) ->
                  check "shutdown waits for cancelled transaction rollback"
                    (ok (C.find Queries.count ()) = 1));
              D.close verifier;
              D.close draining;
              let interrupted_close =
                D.create ~max_connections:1 ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  uri
              in
              D.use interrupted_close (fun _ ->
                  check "close is cancellable while lease remains owned"
                    (try
                       Eio.Time.Timeout.run_exn
                         (Eio.Time.Timeout.seconds
                            (Eio.Stdenv.mono_clock env)
                            0.02)
                         (fun () -> D.close interrupted_close);
                       false
                     with Eio.Time.Timeout -> true);
                  invalid (fun () -> D.use interrupted_close ignore));
              D.close interrupted_close;
              check "interrupted close can be retried"
                (D.size interrupted_close = 0);
              if Uri.scheme uri <> Some "sqlite3" then (
                let timed =
                  D.create ~statement_timeout:0.05 ~sw
                    ~stdenv:(env :> Caqti_eio.stdenv)
                    uri
                in
                let open Caqti.Templater in
                let sleep =
                  static T.(unit -->! int) "SELECT 1 FROM pg_sleep(0.2)"
                in
                check "PostgreSQL statement deadline"
                  (try
                     Httpkit_db_eio.use timed
                       (fun (module C : Caqti_eio.CONNECTION) ->
                         ignore (ok (C.find sleep ())));
                     false
                   with Caqti.Error.Exn _ -> true);
                Httpkit_db_eio.use timed
                  (fun (module C : Caqti_eio.CONNECTION) ->
                    check "pool recovers after statement timeout"
                      (ok (C.find Queries.count ()) = 1));
                Httpkit_db_eio.close timed);
              print_endline
                "PASS real database transactions, cancellation, concurrent \
                 migrations, checksum and pool limits")))
