(** Caqti integration; typed SQL requests remain directly usable. Pools are
    scoped to one Eio switch/domain. Callback connections must not escape or be
    shared. *)

type connection = Caqti_eio.connection
type t

exception Busy

exception Connection_invalidated
(** A previous query failed within the transaction, or a driver call raised.
    Further queries and commit are refused; the pool retires this connection
    after the lease. Rollback/close remain available for cleanup. *)

val create :
  ?max_connections:int ->
  ?max_waiters:int ->
  ?statement_timeout:float ->
  sw:Eio.Switch.t ->
  stdenv:Caqti_eio.stdenv ->
  Uri.t ->
  t
(** PostgreSQL or file-backed SQLite only. SQLite enables foreign keys and a
    bounded lock wait. Statement deadlines are supported by PostgreSQL, not
    SQLite. *)

val use : t -> (connection -> 'a) -> 'a

val transaction : t -> (connection -> 'a) -> 'a
(** Commit on return; rollback on exceptions/cancellation. A failed rollback
    evicts the connection. No implicit retry or nested transaction support. The
    transaction cannot succeed after a query failure, even if the callback
    catches it; subsequent operations raise [Connection_invalidated]. Such
    invalidated connections are retired conservatively. The callback must leave
    transaction/session control and connection validation to the wrapper; it
    must not start, finish or reset the session. PostgreSQL completion retains
    the driver's retry guard; a later lease may reconnect during validation,
    with configured session settings restored. Losing a connection during commit
    can leave the commit outcome unknown; an exception does not prove that the
    database rolled back. Reconciliation and idempotency belong to the
    application. *)

val size : t -> int

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
    trusted code. *)
