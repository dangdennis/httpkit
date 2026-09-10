(** Pure monotonic deadline policy. Callers supply seconds from their runtime's
    monotonic clock. This module never reads a clock or schedules work. *)
type phase = Idle | Head | Body | Write | Shutdown

type policy

val policy :
  ?header:float ->
  ?body_idle:float option ->
  ?write_idle:float option ->
  ?keep_alive:float ->
  ?graceful:float ->
  unit ->
  (policy, string) result
(** Defaults: 10s absolute headers, 30s body/write idle, 30s keep-alive, 10s
    graceful shutdown. Durations must be positive and finite. Only body/write
    idle limits can explicitly be disabled with None. *)

val default : policy
val duration : policy -> phase -> float option

type t

val empty : t

val observe : policy -> now:float -> phase:phase option -> t -> t
(** A phase change starts a deadline. Reobserving Head never slides it. None
    pauses deadlines when input is backpressured by the application. *)

val progress : policy -> now:float -> t -> t
(** Reset idle deadlines after actual progress; never reset a Head deadline. *)

val remaining : now:float -> t -> float option
(** Nonpositive means expired. Callers choose runtime-specific race semantics.
*)
