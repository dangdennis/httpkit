type event =
  | Accepted_input of int
  | Headers of int
  | Data of int * string
  | Complete of int
  | Written of string
  | Accepted
  | Backpressured
  | Rejected of string
  | Closed
  | Woken of int
  | Failed of string
  | Blocked

type observation = int * event

type snapshot = {
  connection : int;
  phase : string;
  incoming : int;
  outgoing : int;
  waiters : int;
  timers : int;
  deadline : int64 option;
  closed : bool;
}

type fault =
  | Correct
  | Drop_write
  | Duplicate_write
  | Overconsume
  | Empty_eof
  | Double_accept
  | Double_complete
  | Body_after_end
  | Reuse_unread
  | Overbuffer
  | Miss_wakeup
  | Sliding_deadline
  | Spin

val faults : fault list
val fault_name : fault -> string
val fault_of_string : string -> (fault, string) result
val observations_to_json : observation list -> Yojson.Safe.t
val snapshots_to_json : snapshot list -> Yojson.Safe.t

val normalize : observation list -> observation list
(** Preserve message identities and all boundaries; merge only adjacent data for
    the same message. *)

module type SUBJECT = sig
  type t

  val create : Scenario.config -> t
  val step : t -> Scenario.action -> observation list
  val snapshots : t -> snapshot list
end
