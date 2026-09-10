type outcome = Exited of int | Signaled of int | Timed_out

val run : seconds:float -> (unit -> unit) -> outcome
val now : unit -> float
