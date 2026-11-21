module D = Httpkit_db_eio

(* Portable statements, so the same cases run on SQLite and PostgreSQL. *)
let int c sql params =
  match D.query c ~kinds:[ Integer ] sql params with
  | [ [ D.Int n ] ] -> Int64.to_int n
  | _ -> failwith ("expected one integer from: " ^ sql)

let text c sql params =
  match D.query c ~kinds:[ String ] sql params with
  | [ [ D.Text s ] ] -> s
  | _ -> failwith ("expected one string from: " ^ sql)

let id n = D.Int (Int64.of_int n)
let insert c n = D.execute c "INSERT INTO items(id) VALUES (?)" [ id n ]
let count c = int c "SELECT COUNT(*) FROM items" []
let pid c = int c "SELECT pg_backend_pid()" []
let timeout c = text c "SELECT current_setting('statement_timeout')" []

let terminate c n =
  int c "SELECT CASE WHEN pg_terminate_backend(?::integer) THEN 1 ELSE 0 END"
    [ id n ]
  = 1

let present c n =
  int c "SELECT COUNT(*) FROM pg_stat_activity WHERE pid=?" [ id n ]

let sleeping c n =
  int c
    "SELECT COUNT(*) FROM pg_stat_activity WHERE pid=? AND wait_event='PgSleep'"
    [ id n ]

(* Caqti requests for the cases that exercise SQLite's native handle. *)
module Queries = struct
  open Caqti.Templater

  let insert = static T.(int -->. unit) "INSERT INTO items(id) VALUES (?)"
  let count = static T.(unit -->! int) "SELECT COUNT(*) FROM items"
  let rows = static T.(unit -->* int) "SELECT id FROM items ORDER BY id"
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

(* A failure the callback catches must still fail the transaction. *)
let callback_faults db ~sqlite =
  let failures =
    [ `Constraint; `Native ] @ if sqlite then [ `Rows; `Call; `Result ] else []
  in
  List.iter
    (fun convenience ->
      List.iter
        (fun failure ->
          let blocked_write = ref false in
          let callback c =
            insert c 99;
            (match (failure, D.sqlite c, D.postgresql c) with
            | `Constraint, _, _ -> (
                match insert c 99 with
                | () -> failwith "duplicate primary key accepted"
                | exception D.Failed _ -> ())
            | `Native, Some (module C), _ -> (
                match C.exec Queries.insert 99 with
                | Error _ -> ()
                | Ok () -> failwith "duplicate primary key accepted")
            | `Native, None, Some (Sqlkit.Driver.Conn ((module P), raw, _)) -> (
                (* the way a generated sqlkit query reaches the server *)
                match
                  P.exec raw ~sql:"INSERT INTO items(id) VALUES (99)" ~params:[]
                with
                | Error _ -> ()
                | Ok _ -> failwith "duplicate primary key accepted")
            | `Rows, Some (module C), _ -> (
                try ignore (C.iter_s Queries.rows (fun _ -> raise Abort) ())
                with Abort -> ())
            | `Call, Some (module C), _ -> (
                try ignore (C.call ~f:(fun _ -> raise Abort) Queries.rows ())
                with Abort -> ())
            | `Result, Some (module C), _ -> (
                match C.iter_s Queries.rows (fun _ -> Error `User_abort) () with
                | Error `User_abort -> ()
                | _ -> failwith "row callback error was not preserved")
            | _ -> failwith "fault does not apply to this backend");
            try insert c 100
            with D.Connection_invalidated -> blocked_write := true
          in
          (match
             if convenience then
               D.use db (fun c ->
                   let (module C) = Option.get (D.sqlite c) in
                   ok
                     (C.with_transaction (fun () ->
                          callback c;
                          Ok ())))
             else D.transaction db callback
           with
          | () -> failwith "caught query failure became successful transaction"
          | exception D.Connection_invalidated -> ());
          check "write after caught failure blocked" !blocked_write;
          D.use db (fun c ->
              check "caught failure committed no rows" (count c = 1)))
        failures)
    (if sqlite then [ false; true ] else [ false ]);
  if sqlite then begin
    D.use db (fun c ->
        let (module C) = Option.get (D.sqlite c) in
        (match
           C.with_transaction (fun () ->
               ok (C.exec Queries.insert 99);
               Error `User_abort)
         with
        | Error `User_abort -> ()
        | _ -> failwith "transaction callback error was not preserved");
        check "explicit error rolls back without poisoning healthy connection"
          (ok (C.find Queries.count ()) = 1);
        check "convenience transaction returns its successful value"
          (ok (C.with_transaction (fun () -> C.find Queries.count ())) = 1));
    D.use db (fun c ->
        let (module C) = Option.get (D.sqlite c) in
        (try ignore (C.iter_s Queries.rows (fun _ -> raise Abort) ())
         with Abort -> ());
        check "driver exception invalidates a nontransactional lease too"
          (try
             ignore (C.find Queries.count ());
             false
           with D.Connection_invalidated -> true))
  end
  else begin
    (* Outside a transaction a refused statement costs nothing. *)
    D.use db (fun c ->
        (match insert c 1 with
        | () -> failwith "duplicate primary key accepted"
        | exception D.Failed { sqlstate; _ } ->
            check "PostgreSQL failure carries its SQLSTATE"
              (sqlstate = Some "23505"));
        check "refused statement outside a transaction keeps the lease"
          (count c = 1));
    (* sqlkit's own transaction, inside ours, is a savepoint: abandoning it
       undoes its work and leaves ours to commit. *)
    D.transaction db (fun c ->
        let conn = Option.get (D.postgresql c) in
        insert c 50;
        (match
           Sqlkit.transaction conn (fun _ ->
               insert c 51;
               Error
                 (Sqlkit.Error.Invalid_argument
                    { operation = "test"; message = "abandon" }))
         with
        | Error (Sqlkit.Error.Invalid_argument _) -> ()
        | _ -> failwith "nested transaction did not report its own error");
        check "savepoint rolled back, outer transaction intact" (count c = 2));
    D.use db (fun c ->
        check "outer transaction committed after an abandoned savepoint"
          (count c = 2);
        D.execute c "DELETE FROM items WHERE id=?" [ id 50 ]);
    (* a transaction left open through the native handle does not leak *)
    let leaked = ref 0 in
    D.use db (fun c ->
        leaked := pid c;
        D.execute c "BEGIN" [];
        insert c 60);
    D.use db (fun c ->
        check "abandoned transaction was not committed" (count c = 1))
  end;
  D.transaction db (fun c ->
      check "healthy transaction after faults" (count c = 1))

let backend_faults ~sw ~stdenv ~clock uri =
  let control = D.create ~max_connections:1 ~sw ~stdenv uri in
  Fun.protect
    ~finally:(fun () -> D.close control)
    (fun () ->
      List.iter
        (fun mode ->
          let victim =
            D.create ~max_connections:1 ~max_waiters:0 ~sw ~stdenv uri
          in
          Fun.protect
            ~finally:(fun () -> D.close victim)
            (fun () ->
              let old_pid = ref 0 and callback_finished = ref false in
              let kill c =
                old_pid := pid c;
                D.use control (fun admin ->
                    check "control connection is separate"
                      (!old_pid > 0 && !old_pid <> pid admin);
                    check "terminated only the owned backend"
                      (terminate admin !old_pid);
                    Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock 5.)
                      (fun () ->
                        while present admin !old_pid <> 0 do
                          Eio.Time.Mono.sleep clock 0.001
                        done))
              in
              let transaction finish =
                D.transaction victim (fun c ->
                    insert c 99;
                    kill c;
                    Fun.protect
                      ~finally:(fun () -> callback_finished := true)
                      finish)
              in
              (match mode with
              | `Exception -> (
                  match transaction (fun () -> raise Abort) with
                  | () -> failwith "lost backend transaction succeeded"
                  | exception Abort -> ())
              | `Commit -> (
                  match transaction (fun () -> ()) with
                  | () -> failwith "commit succeeded after backend termination"
                  | exception D.Failed _ -> ())
              | `Query_error -> (
                  match
                    D.transaction victim (fun c ->
                        insert c 99;
                        kill c;
                        Fun.protect
                          ~finally:(fun () -> callback_finished := true)
                          (fun () ->
                            List.iter
                              (fun n ->
                                match insert c n with
                                | exception
                                    (D.Failed _ | D.Connection_invalidated) ->
                                    ()
                                | () ->
                                    failwith
                                      "write retried outside lost transaction")
                              [ 100; 101 ]))
                  with
                  | () -> failwith "lost transaction query error became success"
                  | exception (D.Failed _ | D.Connection_invalidated) -> ())
              | `Query_cancel ->
                  let entered, notify = Eio.Promise.create () in
                  Eio.Fiber.first
                    (fun () ->
                      D.transaction victim (fun c ->
                          insert c 99;
                          old_pid := pid c;
                          Eio.Promise.resolve notify ();
                          Fun.protect
                            ~finally:(fun () -> callback_finished := true)
                            (fun () ->
                              ignore (int c "SELECT 1 FROM pg_sleep(3)" []);
                              failwith "query completed before cancellation")))
                    (fun () ->
                      Eio.Promise.await entered;
                      Eio.Time.Timeout.run_exn
                        (Eio.Time.Timeout.seconds clock 2.) (fun () ->
                          D.use control (fun admin ->
                              while sleeping admin !old_pid = 0 do
                                Eio.Time.Mono.sleep clock 0.001
                              done)));
                  (* the server was told to stop, not left sleeping *)
                  Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock 2.)
                    (fun () ->
                      D.use control (fun admin ->
                          while sleeping admin !old_pid <> 0 do
                            Eio.Time.Mono.sleep clock 0.001
                          done))
              | `Cancel ->
                  let killed, notify = Eio.Promise.create () in
                  Eio.Fiber.first
                    (fun () ->
                      transaction (fun () ->
                          Eio.Promise.resolve notify ();
                          Eio.Fiber.await_cancel ()))
                    (fun () -> Eio.Promise.await killed));
              check "transaction callback cleanup completed" !callback_finished;
              D.use victim (fun c ->
                  check "lost backend replaced" (pid c <> !old_pid);
                  check "terminated transaction did not commit" (count c = 1);
                  check "replacement restores statement timeout"
                    (timeout c = "10s"));
              let reused = D.transaction victim pid in
              D.use victim (fun c ->
                  check "successful commit keeps its connection" (pid c = reused);
                  kill c);
              D.use victim (fun c ->
                  check "idle connection loss recovers before next lease"
                    (pid c <> reused);
                  check "idle replacement restores statement timeout"
                    (timeout c = "10s"));
              check "no lease outstanding after recovery" (D.size victim = 0)))
        [ `Exception; `Commit; `Query_error; `Query_cancel; `Cancel ]);
  check "control pool retired" (D.size control = 0)

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
              let sqlite = Uri.scheme uri = Some "sqlite3" in
              D.transaction db (fun c -> insert c 1);
              (try
                 D.transaction db (fun c ->
                     insert c 2;
                     raise Abort)
               with Abort -> ());
              let total () = D.use db count in
              check "exception rollback" (total () = 1);
              let inserted, notify = Eio.Promise.create () in
              Eio.Fiber.first
                (fun () ->
                  D.transaction db (fun c ->
                      insert c 3;
                      Eio.Promise.resolve notify ();
                      Eio.Fiber.await_cancel ()))
                (fun () -> Eio.Promise.await inserted);
              check "cancellation rollback" (total () = 1);
              callback_faults db ~sqlite;
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
                 with D.Failed _ -> true);
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
                   ignore (total ());
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
              D.use queued (fun c ->
                  match (D.sqlite c, D.postgresql c) with
                  | Some (module C), _ -> C.disconnect ()
                  | None, Some conn -> ignore (Sqlkit.close conn)
                  | None, None -> ());
              D.use queued (fun c ->
                  check "disconnected resource replaced" (count c = 1));
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
                      D.transaction draining (fun c ->
                          insert c 4;
                          Fun.protect
                            ~finally:(fun () ->
                              Eio.Cancel.protect (fun () ->
                                  Eio.Promise.resolve notify_cleaning ();
                                  Eio.Promise.await release;
                                  check "lease remains usable during cleanup"
                                    (count c = 2);
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
              D.use verifier (fun c ->
                  check "shutdown waits for cancelled transaction rollback"
                    (count c = 1));
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
              if not sqlite then (
                backend_faults ~sw
                  ~stdenv:(env :> Caqti_eio.stdenv)
                  ~clock:(Eio.Stdenv.mono_clock env)
                  uri;
                let timed =
                  D.create ~statement_timeout:0.05 ~sw
                    ~stdenv:(env :> Caqti_eio.stdenv)
                    uri
                in
                let deadline_pid = ref 0 in
                check "PostgreSQL statement deadline carries its SQLSTATE"
                  (try
                     D.use timed (fun c ->
                         deadline_pid := pid c;
                         ignore (int c "SELECT 1 FROM pg_sleep(0.2)" []));
                     false
                   with D.Failed { sqlstate; _ } -> sqlstate = Some "57014");
                D.use timed (fun c ->
                    check "pool recovers after statement timeout" (count c = 1);
                    check "server-side deadline keeps the connection"
                      (pid c = !deadline_pid));
                Httpkit_db_eio.close timed);
              print_endline
                "PASS real database transactions, cancellation, concurrent \
                 migrations, checksum and pool limits")))
