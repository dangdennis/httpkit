type header = { name : string; value : string; sensitive : bool }
(** Private whole-block experiment derived from hpack 0.13.0. *)

type limits = { max_wire : int; max_fields : int; max_bytes : int }
type t

val create : table_capacity:int -> limits -> t
(** Table capacity is limited to 65536 bytes in this experiment. *)

val decode : t -> string -> (header list, string) result
(** All failures are terminal. Caller must close the connection. A successful
    result retains upstream reverse header order. Encoded literal lengths are
    conservatively limited by the remaining decoded budget. This is not an
    incremental network adapter; callers must bound buffering before calling. *)
