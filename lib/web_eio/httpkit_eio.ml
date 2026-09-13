(** Eio application API from [httpkit-eio]. Low-level connections are exposed
    separately by [Httpkit_transport_eio] in [httpkit-transport-eio]. *)

include App
module Common = Common
module Realtime = Realtime
module Files = Files
module Sessions = Sessions
