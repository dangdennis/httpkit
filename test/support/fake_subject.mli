val make : Contract.fault -> (module Contract.SUBJECT)
(** Deliberately simple mutable byte queues. Faults are test fixtures, never
    production switches. *)
