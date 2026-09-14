type access = {
  request_id : string;
  meth : string;
  path : string;
  status : int;
  seconds : float;
}

val access_log : now:(unit -> float) -> (access -> unit) -> App.middleware
(** Logs handler completion, not delivery of the response body. Omits query and
    credentials. *)

val security_headers : App.middleware

val cors :
  origins:string list ->
  methods:string list ->
  headers:string list ->
  ?credentials:bool ->
  unit ->
  App.middleware
(** Exact origins only; credentials never pair with a wildcard. *)

type proxy = Httpkit.Proxy.t = { scheme : string; client_ip : string }

val proxy :
  ?ip_header:Httpkit.Proxy.ip_header ->
  trusted_peer:(string -> bool) ->
  App.request ->
  (proxy option, string) result
(** Shared {!Httpkit.Proxy.resolve} policy. Default remains X-Forwarded-For;
    select [Real_ip] explicitly for a peer that normalizes X-Real-IP. The caller
    must establish immediate-peer trust; no deployment is trusted automatically.
*)
