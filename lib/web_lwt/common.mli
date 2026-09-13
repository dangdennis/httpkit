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

type proxy = { scheme : string; client_ip : string }

val proxy :
  trusted_peer:(string -> bool) -> App.request -> (proxy option, string) result
(** Untrusted peers' forwarding headers are ignored. Trusted peers must supply
    one X-Forwarded-Proto and one IP in X-Forwarded-For; chains and Forwarded
    are rejected. *)
