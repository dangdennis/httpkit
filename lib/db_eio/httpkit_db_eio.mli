(** Caqti integration; typed SQL requests remain directly usable. Pools are
    scoped to one Eio switch/domain. Callback connections must not escape or be
    shared. *)

type connection = Caqti_eio.connection
type t

exception Busy

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
    evicts the connection. No implicit retry or nested transaction support. *)

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
