type t
(** Application-owned example, not an installed httpkit API. One worker domain,
    one admitted job, no waiting-job queue. Use from one application domain and
    keep all callers within the owning switch's lifetime. *)

val create : sw:Eio.Switch.t -> _ Eio.Domain_manager.t -> t

val run : t -> (unit -> 'a) -> ('a, [ `Busy ]) result
(** Jobs must terminate and only access thread-safe captured data. Cancellation
    waits for an admitted job to finish before releasing its slot. Successful
    results are not delivered to a cancelled caller. Job exceptions propagate
    after slot release. The caller decides how to turn [Busy] into an HTTP
    reply. *)
