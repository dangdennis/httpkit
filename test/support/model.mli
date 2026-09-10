type t
(** Independent immutable lifecycle oracle for the synthetic subject. *)

val create : Scenario.config -> t
val step : t -> Scenario.action -> t * Contract.observation list
val snapshots : t -> Contract.snapshot list
