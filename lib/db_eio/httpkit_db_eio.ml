type connection = Caqti_eio.connection
type backend = Postgresql | Sqlite
type resource = { connection : connection; live : bool ref }

type t = {
  pool : resource Eio.Pool.t;
  resources : resource list ref;
  changed : Eio.Condition.t;
  dispose : resource -> unit;
  backend : backend;
  max_users : int;
  mutable users : int;
  mutable closed : bool;
}

exception Busy

let checked r = Caqti_eio.or_fail r

let exec (module C : Caqti_eio.CONNECTION) sql =
  let open Caqti.Templater in
  checked (C.exec (dynamic T.(unit -->. unit) sql) ())

let create ?(max_connections = 8) ?(max_waiters = 32) ?(statement_timeout = 10.)
    ~sw ~stdenv uri =
  if
    max_connections <= 0 || max_waiters < 0
    || max_waiters > max_int - max_connections
    || (not (Float.is_finite statement_timeout))
    || statement_timeout <= 0.
    || statement_timeout > 2147483.647
  then invalid_arg "database limits";
  let backend =
    match Uri.scheme uri with
    | Some "postgresql" | Some "postgres" -> Postgresql
    | Some "sqlite3" when Uri.path uri <> "" && Uri.path uri <> ":memory:" ->
        Sqlite
    | _ -> invalid_arg "expected PostgreSQL or file-backed SQLite URI"
  in
  let post_connect ((module C : Caqti_eio.CONNECTION) as connection) =
    (match backend with
    | Postgresql ->
        let milliseconds = ceil (statement_timeout *. 1000.) in
        exec connection
          (Printf.sprintf "SET statement_timeout TO %.0f" milliseconds)
    | Sqlite ->
        exec connection "PRAGMA foreign_keys=ON";
        let open Caqti.Templater in
        ignore
          (checked
             (C.find (static T.(unit -->! int) "PRAGMA busy_timeout=5000") ())));
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
    let module C = struct
      include Raw

      let disconnect () =
        if !live then (
          live := false;
          Eio.Cancel.protect Raw.disconnect)
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
    if !(resource.live) && C.validate () then (
      ignore (post_connect resource.connection);
      true)
    else false
  in
  let pool = Eio.Pool.create ~validate ~dispose max_connections allocate in
  let t =
    {
      pool;
      resources;
      dispose;
      changed = Eio.Condition.create ();
      backend;
      max_users = max_connections + max_waiters;
      users = 0;
      closed = false;
    }
  in
  Eio.Switch.on_release sw (fun () ->
      t.closed <- true;
      resources := []);
  t

let use t f =
  if t.closed then invalid_arg "closed database pool";
  if t.users >= t.max_users then raise Busy;
  t.users <- t.users + 1;
  Fun.protect
    ~finally:(fun () ->
      t.users <- t.users - 1;
      Eio.Condition.broadcast t.changed)
    (fun () ->
      Eio.Pool.use t.pool (fun resource ->
          if t.closed then invalid_arg "closed database pool";
          f resource.connection))

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

let transaction t f = use t (fun c -> in_transaction c (fun () -> f c))
let size t = List.length !(t.resources)

let close t =
  t.closed <- true;
  while t.users > 0 do
    Eio.Condition.await_no_mutex t.changed
  done;
  Eio.Cancel.protect (fun () -> List.iter t.dispose !(t.resources))

type migration = {
  version : int;
  postgresql : string list;
  sqlite : string list;
}

(* Migration history is persistent application data; package renames must not
   create a new history table and replay already applied migrations. *)
module Q = struct
  open Caqti.Templater

  let history =
    static
      T.(unit -->* t2 int string)
      "SELECT version, checksum FROM http_kit_migrations ORDER BY version"

  let insert =
    static
      T.(t2 int string -->. unit)
      "INSERT INTO http_kit_migrations (version, checksum) VALUES (?, ?)"

  let lock =
    static T.(unit -->! int) "SELECT 1 FROM pg_advisory_xact_lock(1798640203)"
end

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
  use t (fun ((module C : Caqti_eio.CONNECTION) as c) ->
      in_transaction ~immediate:(t.backend = Sqlite) c (fun () ->
          if t.backend = Postgresql then ignore (checked (C.find Q.lock ()));
          exec c
            "CREATE TABLE IF NOT EXISTS http_kit_migrations (version INTEGER \
             PRIMARY KEY, checksum VARCHAR(64) NOT NULL)";
          let history = checked (C.collect_list Q.history ()) in
          let rec apply history migrations =
            match (history, migrations) with
            | [], [] -> ()
            | [], (version, checksum, sql) :: rest ->
                List.iter (exec c) sql;
                checked (C.exec Q.insert (version, checksum));
                apply [] rest
            | (version, checksum) :: old, (next, digest, _) :: rest
              when version = next && checksum = digest ->
                apply old rest
            | _ -> invalid_arg "migration history or checksum mismatch"
          in
          apply history migrations))
