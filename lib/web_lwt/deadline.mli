val within :
  Httpkit_transport_lwt.clock -> float -> (unit -> 'a Lwt.t) -> 'a Lwt.t
(** Race work against a deadline. Cancel and join both owned branches before
    returning, raising, or completing external cancellation. *)
