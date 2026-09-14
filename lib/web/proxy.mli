(** Explicit forwarding policy. Header presence never authenticates a peer. *)
type ip_header = Forwarded_for | Real_ip

type t = { scheme : string; client_ip : string }

val resolve :
  ?ip_header:ip_header ->
  trusted_peer:(string -> bool) ->
  peer:string ->
  Httpkit_core.Headers.t ->
  (t option, string) result
(** Untrusted peers return [Ok None] without interpreting forwarding fields.
    Trusted peers must send exactly one http/https X-Forwarded-Proto and exactly
    one IP in the selected header (X-Forwarded-For by default, or X-Real-IP).
    Lists, duplicate selected fields and RFC Forwarded are rejected. The other
    IP header and X-Forwarded-Host are ignored, never used as fallback or origin
    authority. Use configured application origins separately. The caller owns
    immediate-peer authentication; exceptions from [trusted_peer] propagate. *)
