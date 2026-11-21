(* PostgreSQL runs on sqlkit's pure OCaml driver; SQLite runs on Caqti. The two
   halves share admission control, shutdown, the transaction contract and the
   portable statement helpers, and nothing else. *)

type backend = Postgresql | Sqlite
type resource = { connection : Caqti_eio.connection; live : bool ref }

(* One PostgreSQL lease. [conn] is the pool's handle wrapped so that every
   statement, whichever API issued it, is seen here. [depth] is sqlkit's own
   transaction depth for that handle. *)
type flags = {
  mutable active : bool;
  mutable failed : bool;
  mutable live : bool;
}

type lease = { conn : Sqlkit.conn; flags : flags; depth : int ref }

type connection =
  | Sqlite_connection of Caqti_eio.connection
  | Postgresql_lease of lease

type pool =
  | Sqlite_pool of {
      pool : resource Eio.Pool.t;
      resources : resource list ref;
      dispose : resource -> unit;
    }
  | Postgresql_pool of {
      pool : Sqlkit_pgwire.Pool.t;
      mutable leases : int;
      stop : unit -> unit;
    }

type t = {
  pool : pool;
  changed : Eio.Condition.t;
  backend : backend;
  max_users : int;
  mutable users : int;
  mutable closed : bool;
}

exception Busy
exception Connection_invalidated
exception Failed of { sqlstate : string option; message : string }

let checked r = Caqti_eio.or_fail r

let exec (module C : Caqti_eio.CONNECTION) sql =
  let open Caqti.Templater in
  checked (C.exec (dynamic T.(unit -->. unit) sql) ())

let create_sqlite ~max_connections ~max_users ~sw ~stdenv uri =
  let backend = Sqlite in
  let post_connect ((module C : Caqti_eio.CONNECTION) as connection) =
    exec connection "PRAGMA foreign_keys=ON";
    let open Caqti.Templater in
    ignore
      (checked
         (C.find (static T.(unit -->! int) "PRAGMA busy_timeout=5000") ()));
    Ok ()
  in
  let resources = ref [] in
  let dispose resource =
    resources := List.filter (fun r -> r != resource) !resources;
    let module C = (val resource.connection : Caqti_eio.CONNECTION) in
    Eio.Cancel.protect C.disconnect
  in
  let allocate () =
    let connection = checked (Caqti_eio_unix.connect ~sw ~stdenv uri) in
    let module Raw = (val connection : Caqti_eio.CONNECTION) in
    let live = ref true in
    let active = ref false and failed = ref false in
    let module C = struct
      include Raw

      let disconnect () =
        if !live then (
          live := false;
          Eio.Cancel.protect Raw.disconnect)

      let guard f =
        if (not !live) || !failed then raise Connection_invalidated;
        match f () with
        | Error _ as error ->
            if !active then failed := true;
            error
        | Ok _ as result -> result
        | exception exn ->
            let trace = Printexc.get_raw_backtrace () in
            (* A driver may reset its session when a retrieval callback raises.
               Never let a caller catch that failure and continue on the reset
               session, inside or outside an explicit transaction. *)
            failed := true;
            Printexc.raise_with_backtrace exn trace

      let call ~f q p = guard (fun () -> Raw.call ~f q p)
      let exec q p = guard (fun () -> Raw.exec q p)

      let exec_with_affected_count q p =
        guard (fun () -> Raw.exec_with_affected_count q p)

      let find q p = guard (fun () -> Raw.find q p)
      let find_opt q p = guard (fun () -> Raw.find_opt q p)
      let fold q f p a = guard (fun () -> Raw.fold q f p a)
      let fold_s q f p a = guard (fun () -> Raw.fold_s q f p a)
      let iter_s q f p = guard (fun () -> Raw.iter_s q f p)
      let collect_list q p = guard (fun () -> Raw.collect_list q p)
      let rev_collect_list q p = guard (fun () -> Raw.rev_collect_list q p)

      let populate ~table ~columns row_type data =
        guard (fun () -> Raw.populate ~table ~columns row_type data)

      let deallocate q = guard (fun () -> Raw.deallocate q)

      let set_statement_timeout timeout =
        guard (fun () -> Raw.set_statement_timeout timeout)

      let validate () =
        (not !active) && (not !failed) && !live && Raw.validate ()

      let check f = if !failed || not !live then f false else Raw.check f

      let start () =
        if !active then invalid_arg "nested database transaction";
        match guard Raw.start with
        | Ok () ->
            active := true;
            Ok ()
        | Error _ as error -> error

      let commit () =
        match guard Raw.commit with
        | Ok () ->
            active := false;
            Ok ()
        | Error _ as error -> error

      let rollback () =
        if not !live then raise Connection_invalidated;
        match Raw.rollback () with
        | Ok () ->
            active := false;
            Ok ()
        | Error _ as error ->
            failed := true;
            error
        | exception exn ->
            let trace = Printexc.get_raw_backtrace () in
            failed := true;
            Printexc.raise_with_backtrace exn trace

      let cleanup () =
        Eio.Cancel.protect (fun () ->
            match rollback () with
            | Ok () -> ()
            | Error _ | (exception _) -> disconnect ())

      (* The inherited convenience method closes over Raw.commit. Keep both
         transaction entry points on the guarded connection. *)
      let with_transaction f =
        match start () with
        | Error _ as error -> error
        | Ok () -> (
            match
              match f () with
              | Error _ as error -> error
              | Ok value -> Result.map (fun () -> value) (commit ())
            with
            | Ok _ as result -> result
            | Error _ as error ->
                cleanup ();
                error
            | exception exn ->
                let trace = Printexc.get_raw_backtrace () in
                cleanup ();
                Printexc.raise_with_backtrace exn trace)
    end in
    let connection = (module C : Caqti_eio.CONNECTION) in
    let resource = { connection; live } in
    try
      ignore (post_connect connection);
      resources := resource :: !resources;
      resource
    with exn ->
      let trace = Printexc.get_raw_backtrace () in
      dispose resource;
      Printexc.raise_with_backtrace exn trace
  in
  let validate resource =
    let module C = (val resource.connection : Caqti_eio.CONNECTION) in
    try
      if !(resource.live) && C.validate () then (
        ignore (post_connect resource.connection);
        true)
      else false
    with Caqti.Error.Exn _ ->
      (* Idle peer loss can arrive after validate's socket-status check. No
         lease callback has run yet; let the pool retire this resource. Fresh
         allocation failures and cancellation still propagate. *)
      false
  in
  let pool = Eio.Pool.create ~validate ~dispose max_connections allocate in
  Eio.Switch.on_release sw (fun () -> resources := []);
  {
    pool = Sqlite_pool { pool; resources; dispose };
    changed = Eio.Condition.create ();
    backend;
    max_users;
    users = 0;
    closed = false;
  }

(* ---------- PostgreSQL ---------- *)

(* A switch of our own, so [close] can release the pool's connections before
   the caller's switch ends. The daemon holds it open until told to stop. *)
let scoped ~sw =
  let ready, set_ready = Eio.Promise.create () in
  let stop, set_stop = Eio.Promise.create () in
  let finished, set_finished = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve set_finished ())
        (fun () ->
          Eio.Switch.run (fun inner ->
              Eio.Promise.resolve set_ready inner;
              Eio.Promise.await stop));
      `Stop_daemon);
  ( Eio.Promise.await ready,
    fun () ->
      if not (Eio.Promise.is_resolved stop) then Eio.Promise.resolve set_stop ();
      Eio.Promise.await finished )

let failed_of_error e =
  Failed
    {
      sqlstate = Option.map Sqlkit.Sqlstate.to_string (Sqlkit.Error.sqlstate e);
      message = Sqlkit.Error.to_string e;
    }

let failed_of_driver (e : Sqlkit.Driver.error) =
  Failed
    {
      sqlstate = Option.map Sqlkit.Sqlstate.to_string e.sqlstate;
      message = e.message;
    }

let create_postgresql ~max_connections ~max_users ~statement_timeout ~sw ~stdenv
    uri =
  let limits =
    {
      Sqlkit.Limits.default with
      statement_timeout_ms = int_of_float (ceil (statement_timeout *. 1000.));
    }
  in
  let inner, stop = scoped ~sw in
  match
    (* The client deadline sits behind the server's, so a statement that
       overruns is normally ended by the server and keeps its connection. *)
    Sqlkit_pgwire.Pool.create ~sw:inner ~net:stdenv#net ~clock:stdenv#mono_clock
      ~max_size:max_connections
      ~acquire_timeout:(Float.max 30. (3. *. statement_timeout))
      ~query_timeout:(statement_timeout +. 5.) ~limits (Uri.to_string uri)
  with
  | Ok pool ->
      {
        pool = Postgresql_pool { pool; leases = 0; stop };
        changed = Eio.Condition.create ();
        backend = Postgresql;
        max_users;
        users = 0;
        closed = false;
      }
  | Error (Sqlkit.Error.Invalid_argument { message; _ }) ->
      stop ();
      invalid_arg ("database URI: " ^ message)
  | Error e ->
      stop ();
      raise (failed_of_error e)

let create ?(max_connections = 8) ?(max_waiters = 32) ?(statement_timeout = 10.)
    ~sw ~stdenv uri =
  if
    max_connections <= 0 || max_waiters < 0
    || max_waiters > max_int - max_connections
    || (not (Float.is_finite statement_timeout))
    || statement_timeout <= 0.
    || statement_timeout > 2147483.647
  then invalid_arg "database limits";
  let max_users = max_connections + max_waiters in
  match Uri.scheme uri with
  | Some "postgresql" | Some "postgres" ->
      create_postgresql ~max_connections ~max_users ~statement_timeout ~sw
        ~stdenv uri
  | Some "sqlite3" when Uri.path uri <> "" && Uri.path uri <> ":memory:" ->
      create_sqlite ~max_connections ~max_users ~sw ~stdenv uri
  | _ -> invalid_arg "expected PostgreSQL or file-backed SQLite URI"

(* Wrap the pool's handle so that a failed statement inside a transaction is
   remembered even when the caller swallows the error, and so that nothing more
   runs on a lease that has been invalidated. Generated sqlkit queries and the
   portable helpers below both go through this. *)
let guarded (Sqlkit.Driver.Conn ((module D), raw, state)) =
  let flags = { active = false; failed = false; live = true } in
  let module G = struct
    include D

    let refused =
      Sqlkit.Driver.error "connection invalidated by an earlier failure"

    let guard f =
      if flags.failed || not flags.live then Error refused
      else
        match f () with
        | Ok _ as ok -> ok
        | Error _ as error ->
            if flags.active then flags.failed <- true;
            error

    let query c ~sql ~params ~columns =
      guard (fun () -> D.query c ~sql ~params ~columns)

    let exec c ~sql ~params = guard (fun () -> D.exec c ~sql ~params)
    let copy c ~sql ~rows = guard (fun () -> D.copy c ~sql ~rows)

    let close c =
      flags.live <- false;
      D.close c
  end in
  match Sqlkit.Driver.make ~observe:state.observe (module G) raw with
  | Sqlkit.Driver.Conn (_, _, wrapped) as conn ->
      { conn; flags; depth = wrapped.depth }

(* Transaction control bypasses the guard: ROLLBACK has to run on a lease whose
   transaction already failed. *)
let control lease sql =
  let (Sqlkit.Driver.Conn ((module D), raw, _)) = lease.conn in
  D.exec raw ~sql ~params:[]

let discard lease =
  let (Sqlkit.Driver.Conn ((module D), raw, _)) = lease.conn in
  D.close raw

let rollback_lease lease =
  Eio.Cancel.protect (fun () ->
      (match control lease "ROLLBACK" with
      | Ok _ -> ()
      | Error _ -> discard lease);
      lease.flags.active <- false;
      lease.depth := 0)

(* A statement that failed inside the transaction aborted it on the server,
   where COMMIT would then quietly roll back and report success. The callback
   may have caught that failure, so it is checked here, not left to the server's
   answer. Depth 1 makes a nested [Sqlkit.transaction] use a savepoint instead
   of starting, and ending, a transaction of its own. *)
let lease_transaction lease f =
  if lease.flags.active then invalid_arg "nested database transaction";
  if lease.flags.failed || not lease.flags.live then
    raise Connection_invalidated;
  (match control lease "BEGIN" with
  | Ok _ -> ()
  | Error e -> raise (failed_of_driver e));
  lease.flags.active <- true;
  lease.depth := 1;
  match f () with
  | value ->
      if lease.flags.failed || not lease.flags.live then (
        rollback_lease lease;
        raise Connection_invalidated);
      (match control lease "COMMIT" with
      | Ok _ ->
          lease.flags.active <- false;
          lease.depth := 0
      | Error e ->
          (* The outcome is unknown; the connection is not reused. *)
          lease.flags.failed <- true;
          Eio.Cancel.protect (fun () -> discard lease);
          raise (failed_of_driver e));
      value
  | exception exn ->
      let trace = Printexc.get_raw_backtrace () in
      rollback_lease lease;
      Printexc.raise_with_backtrace exn trace

let admitted t f =
  if t.closed then invalid_arg "closed database pool";
  if t.users >= t.max_users then raise Busy;
  t.users <- t.users + 1;
  Fun.protect
    ~finally:(fun () ->
      t.users <- t.users - 1;
      Eio.Condition.broadcast t.changed)
    f

let use t f =
  admitted t (fun () ->
      match t.pool with
      | Sqlite_pool { pool; _ } ->
          Eio.Pool.use pool (fun resource ->
              if t.closed then invalid_arg "closed database pool";
              f (Sqlite_connection resource.connection))
      | Postgresql_pool p -> (
          (* sqlkit turns a callback's exception into an error value. The
             callback's own exceptions are part of this module's contract, so
             they are carried out and raised again unchanged. *)
          let outcome =
            Sqlkit_pgwire.Pool.use p.pool (fun conn ->
                if t.closed then invalid_arg "closed database pool";
                let lease = guarded conn in
                p.leases <- p.leases + 1;
                Fun.protect
                  ~finally:(fun () ->
                    p.leases <- p.leases - 1;
                    (* Left open, the transaction would make the pool discard
                       the connection; ending it here keeps it. *)
                    if lease.flags.active then rollback_lease lease;
                    lease.flags.live <- false)
                  (fun () ->
                    match f (Postgresql_lease lease) with
                    | value -> Ok (Ok value)
                    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                    | exception exn ->
                        Ok (Error (exn, Printexc.get_raw_backtrace ()))))
          in
          match outcome with
          | Ok (Ok value) -> value
          | Ok (Error (exn, trace)) -> Printexc.raise_with_backtrace exn trace
          | Error e -> raise (failed_of_error e)))

let rollback (module C : Caqti_eio.CONNECTION) =
  Eio.Cancel.protect (fun () ->
      match C.rollback () with
      | Ok () -> ()
      | Error _ -> C.disconnect ()
      | exception _ -> C.disconnect ())

let in_transaction ?(immediate = false) ((module C : Caqti_eio.CONNECTION) as c)
    f =
  if immediate then exec c "BEGIN IMMEDIATE" else checked (C.start ());
  try
    let value = f () in
    checked (C.commit ());
    value
  with exn ->
    let trace = Printexc.get_raw_backtrace () in
    rollback c;
    Printexc.raise_with_backtrace exn trace

let within ?immediate connection f =
  match connection with
  | Sqlite_connection c -> in_transaction ?immediate c f
  | Postgresql_lease lease -> lease_transaction lease f

let transaction t f = use t (fun c -> within c (fun () -> f c))

let size t =
  match t.pool with
  | Sqlite_pool { resources; _ } -> List.length !resources
  | Postgresql_pool p -> p.leases

let close t =
  t.closed <- true;
  while t.users > 0 do
    Eio.Condition.await_no_mutex t.changed
  done;
  Eio.Cancel.protect (fun () ->
      match t.pool with
      | Sqlite_pool { resources; dispose; _ } -> List.iter dispose !resources
      | Postgresql_pool p -> p.stop ())

let postgresql = function
  | Postgresql_lease lease -> Some lease.conn
  | Sqlite_connection _ -> None

let sqlite = function
  | Sqlite_connection c -> Some c
  | Postgresql_lease _ -> None

(* ---------- portable statements ---------- *)

type value = Null | Int of int64 | Text of string
type kind = Integer | String

(* [?] becomes [$n] for PostgreSQL, outside quoted text. *)
let numbered sql =
  let b = Buffer.create (String.length sql + 8) in
  let n = ref 0 and quote = ref None in
  String.iter
    (fun c ->
      match (!quote, c) with
      | None, '?' ->
          incr n;
          Buffer.add_char b '$';
          Buffer.add_string b (string_of_int !n)
      | None, ('\'' | '"') ->
          quote := Some c;
          Buffer.add_char b c
      | Some q, c when c = q ->
          quote := None;
          Buffer.add_char b c
      | _ -> Buffer.add_char b c)
    sql;
  Buffer.contents b

let pg_value = function
  | Null -> Sqlkit.Value.Null
  | Int n -> Sqlkit.Value.Text (Int64.to_string n)
  | Text s -> Sqlkit.Value.Text s

type arguments = Arguments : 'a Caqti_type.t * 'a -> arguments

let rec arguments = function
  | [] -> Arguments (Caqti_type.unit, ())
  | v :: rest -> (
      let (Arguments (t, x)) = arguments rest in
      match v with
      | Text s -> Arguments (Caqti_type.(t2 string t), (s, x))
      | Int n -> Arguments (Caqti_type.(t2 int64 t), (n, x))
      | Null -> Arguments (Caqti_type.(t2 (option string) t), (None, x)))

type columns = Columns : 'a Caqti_type.t * ('a -> value list) -> columns

let rec columns = function
  | [] -> Columns (Caqti_type.unit, fun () -> [])
  | kind :: rest -> (
      let (Columns (t, read)) = columns rest in
      match kind with
      | Integer ->
          Columns
            ( Caqti_type.(t2 (option int64) t),
              fun (v, x) ->
                (match v with Some n -> Int n | None -> Null) :: read x )
      | String ->
          Columns
            ( Caqti_type.(t2 (option string) t),
              fun (v, x) ->
                (match v with Some s -> Text s | None -> Null) :: read x ))

let sqlite_failed e = Failed { sqlstate = None; message = Caqti_error.show e }

let query connection ~kinds sql params =
  match connection with
  | Postgresql_lease lease -> (
      if lease.flags.failed || not lease.flags.live then
        raise Connection_invalidated;
      let (Sqlkit.Driver.Conn ((module D), raw, _)) = lease.conn in
      match
        D.query raw ~sql:(numbered sql) ~params:(List.map pg_value params)
          ~columns:(List.length kinds)
      with
      | Error e -> raise (failed_of_driver e)
      | Ok rows ->
          List.map
            (fun row ->
              if Array.length row <> List.length kinds then
                invalid_arg "database result does not have the declared columns";
              List.mapi
                (fun i kind ->
                  match (row.(i), kind) with
                  | Sqlkit.Value.Null, _ -> Null
                  | Sqlkit.Value.Text s, String -> Text s
                  | Sqlkit.Value.Text s, Integer -> (
                      match Int64.of_string_opt s with
                      | Some n -> Int n
                      | None -> invalid_arg "database result is not an integer")
                  | (Bool _ | Int _ | Float _ | Octets _), _ ->
                      invalid_arg "unexpected database value")
                kinds)
            rows)
  | Sqlite_connection (module C) -> (
      let (Arguments (at, args)) = arguments params in
      let (Columns (rt, read)) = columns kinds in
      let request =
        Caqti_request.create ~oneshot:true at rt Caqti_mult.zero_or_more
          (fun _ -> Caqti_query.of_string_exn sql)
      in
      match C.collect_list request args with
      | Ok rows -> List.map read rows
      | Error e -> raise (sqlite_failed e))

let execute connection sql params =
  match connection with
  | Postgresql_lease lease -> (
      if lease.flags.failed || not lease.flags.live then
        raise Connection_invalidated;
      let (Sqlkit.Driver.Conn ((module D), raw, _)) = lease.conn in
      match
        D.exec raw ~sql:(numbered sql) ~params:(List.map pg_value params)
      with
      | Ok _ -> ()
      | Error e -> raise (failed_of_driver e))
  | Sqlite_connection (module C) -> (
      let (Arguments (at, args)) = arguments params in
      let request =
        Caqti_request.create ~oneshot:true at Caqti_type.unit Caqti_mult.zero
          (fun _ -> Caqti_query.of_string_exn sql)
      in
      match C.exec request args with
      | Ok () -> ()
      | Error e -> raise (sqlite_failed e))

type migration = {
  version : int;
  postgresql : string list;
  sqlite : string list;
}

let migrate t migrations =
  if List.length migrations > 10000 then invalid_arg "migration count";
  let previous = ref 0 in
  List.iter
    (fun m ->
      if m.version <= !previous then invalid_arg "migration order";
      previous := m.version)
    migrations;
  let digest m =
    let sql =
      match t.backend with Postgresql -> m.postgresql | Sqlite -> m.sqlite
    in
    if
      sql = []
      || List.length sql > 1000
      || List.exists (fun s -> String.length s > 1048576) sql
    then invalid_arg "migration SQL limits";
    let input =
      String.concat ""
        (List.map (fun s -> string_of_int (String.length s) ^ ":" ^ s) sql)
    in
    (Digestif.SHA256.(to_hex (digest_string input)), sql)
  in
  let migrations =
    List.map
      (fun m ->
        let checksum, sql = digest m in
        (m.version, checksum, sql))
      migrations
  in
  (* Migration history is persistent application data; package renames must
     not create a new history table and replay already applied migrations. *)
  use t (fun c ->
      within ~immediate:true c (fun () ->
          if t.backend = Postgresql then
            ignore
              (query c ~kinds:[ Integer ]
                 "SELECT 1 FROM pg_advisory_xact_lock(1798640203)" []);
          (* Trusted SQL runs verbatim: a [?] in it is the author's, not a
             placeholder. *)
          let run sql =
            match c with
            | Sqlite_connection _ -> execute c sql []
            | Postgresql_lease lease -> (
                if lease.flags.failed then raise Connection_invalidated;
                let (Sqlkit.Driver.Conn ((module D), raw, _)) = lease.conn in
                match D.exec raw ~sql ~params:[] with
                | Ok _ -> ()
                | Error e -> raise (failed_of_driver e))
          in
          run
            "CREATE TABLE IF NOT EXISTS http_kit_migrations (version INTEGER \
             PRIMARY KEY, checksum VARCHAR(64) NOT NULL)";
          let history =
            List.map
              (function
                | [ Int version; Text checksum ] ->
                    (Int64.to_int version, checksum)
                | _ -> invalid_arg "migration history or checksum mismatch")
              (query c ~kinds:[ Integer; String ]
                 "SELECT version, checksum FROM http_kit_migrations ORDER BY \
                  version"
                 [])
          in
          let rec apply history migrations =
            match (history, migrations) with
            | [], [] -> ()
            | [], (version, checksum, sql) :: rest ->
                List.iter run sql;
                execute c
                  "INSERT INTO http_kit_migrations (version, checksum) VALUES \
                   (?, ?)"
                  [ Int (Int64.of_int version); Text checksum ];
                apply [] rest
            | (version, checksum) :: old, (next, digest, _) :: rest
              when version = next && checksum = digest ->
                apply old rest
            | _ -> invalid_arg "migration history or checksum mismatch"
          in
          apply history migrations))
