(** Database pools for PostgreSQL and file-backed SQLite.

    PostgreSQL runs on sqlkit's pure OCaml driver ([sqlkit-pgwire]); SQLite runs
    on Caqti. A lease is a {!connection}: reach the native handle with
    {!val-postgresql} or {!val-sqlite}, or use the portable {!query} and
    {!execute}, which work on both.

    Pools are scoped to one Eio switch/domain. Callback connections must not
    escape or be shared. *)

type t
type connection

exception Busy

exception Connection_invalidated
(** A previous query failed within the transaction, or a driver call raised.
    Further queries and commit are refused; the connection is not handed out
    again in that state. Rollback/close remain available for cleanup. *)

exception Failed of { sqlstate : string option; message : string }
(** A database error from {!query}, {!execute}, {!transaction}, {!migrate} or,
    on PostgreSQL, from acquiring a connection. [sqlstate] is PostgreSQL's
    five-character code; SQLite errors carry none. Errors from a native handle
    keep that library's own form. *)

val create :
  ?max_connections:int ->
  ?max_waiters:int ->
  ?statement_timeout:float ->
  sw:Eio.Switch.t ->
  stdenv:Caqti_eio.stdenv ->
  Uri.t ->
  t
(** PostgreSQL ([postgresql://]) or file-backed SQLite ([sqlite3:]) only. SQLite
    enables foreign keys and a bounded lock wait. Statement deadlines are
    supported by PostgreSQL, not SQLite; the server enforces them, with a client
    deadline five seconds behind that costs the connection if it is ever
    reached.

    PostgreSQL connection strings are sqlkit-pgwire's: [sslmode] defaults to
    [prefer] (TLS when offered, certificate not verified); ask for [verify-full]
    on a network you do not control. A parameter the driver cannot honour raises
    [Invalid_argument]. *)

val use : t -> (connection -> 'a) -> 'a

val transaction : t -> (connection -> 'a) -> 'a
(** Commit on return; rollback on exceptions/cancellation. A failed rollback
    evicts the connection. No implicit retry. The transaction cannot succeed
    after a query failure, even if the callback catches it; subsequent
    operations raise [Connection_invalidated] (through a native PostgreSQL
    handle they return an error instead). The callback must leave transaction
    and session control to the wrapper, with one exception: on PostgreSQL,
    [Sqlkit.transaction] may be used inside and nests as a savepoint. Losing a
    connection during commit can leave the commit outcome unknown; an exception
    does not prove that the database rolled back. Reconciliation and idempotency
    belong to the application. *)

val postgresql : connection -> Sqlkit.conn option
(** The lease as a sqlkit handle, for generated queries. [None] on SQLite. *)

val sqlite : connection -> Caqti_eio.connection option
(** The lease as a Caqti connection. [None] on PostgreSQL. *)

(** {1 Portable statements}

    Enough to write a statement once for both backends: [?] placeholders
    (outside quoted text), integer and text values. Raises {!Failed} on a
    database error. *)

type value = Null | Int of int64 | Text of string
type kind = Integer | String

val query :
  connection -> kinds:kind list -> string -> value list -> value list list
(** One [kind] per result column, in order. *)

val execute : connection -> string -> value list -> unit

val size : t -> int
(** SQLite: connections currently open. PostgreSQL: leases currently in use;
    idle connections are owned by the driver's pool and not counted. *)

val close : t -> unit
(** Stops admission immediately, then waits for every lease callback, including
    cancellation cleanup and transaction rollback, before disconnecting idle
    resources. Repeated calls are harmless. The wait is cancellable: after an
    interrupted close the pool remains terminal, and the owner must retry close
    or finish its switch. Do not call close from inside this pool's own lease
    callback, as it would wait for itself. *)

type migration = {
  version : int;
  postgresql : string list;
  sqlite : string list;
}

val migrate : t -> migration list -> unit
(** Ordered, append-only migrations. Serializes writers in the database,
    verifies checksums/history, and applies the batch transactionally. SQL is
    trusted code and runs verbatim. *)
