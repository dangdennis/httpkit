val partitions : string -> string list list
val single_splits : string -> string list list

type node = { id : int; after : int list; action : Scenario.action }

val topological :
  ?limit:int -> node list -> (Scenario.action list list * bool, string) result
