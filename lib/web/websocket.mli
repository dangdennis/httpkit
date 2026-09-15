(** RFC 6455 server profile, without extensions. Bounded complete-message
    events. *)

type event =
  | Text of string
  | Binary of string
  | Ping of string
  | Pong of string
  | Close of int option * string

type t

val server : ?max_frame:int -> ?max_message:int -> unit -> t

val feed : t -> string -> (event list, string) result
(** At most 64 KiB per call. Incomplete frames are buffered within the
    configured frame limit plus one input chunk and framing overhead. Buffer
    capacity may round up geometrically; message assembly has its separate
    message limit. Protocol failure is terminal and releases accumulated
    buffers. *)

val eof : t -> (unit, string) result

val encode : event -> (string, string) result
(** Unmasked final server frames. *)

val handshake :
  allowed_origins:string list ->
  unit Httpkit_core.Request.t ->
  (unit Httpkit_core.Response.t, string) result
(** One exact allowlisted Origin is required. No subprotocol or extension
    negotiation. *)
