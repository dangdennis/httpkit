type result = { scenario : Scenario.t; attempts : int; exhausted : bool }

val minimize :
  ?max_attempts:int ->
  ?expired:(unit -> bool) ->
  Contract.fault ->
  Scenario.t ->
  result
(** Bounded delta-debugging; prerequisites and original failure category are
    retained. *)
