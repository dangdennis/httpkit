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
(** Terminal for this wrapper; drains checked-out connections. *)

type migration = {
  version : int;
  postgresql : string list;
  sqlite : string list;
}

val migrate : t -> migration list -> unit
(** Ordered, append-only migrations. Serializes writers in the database,
    verifies checksums/history, and applies the batch transactionally. SQL is
    trusted code. *)
