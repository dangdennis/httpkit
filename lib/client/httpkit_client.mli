open Httpkit_core

exception Unframed_https_response

val check_response :
  ?meth:Httpkit_core.Method.t -> tls:bool -> unit Response.t -> unit
(** Legacy conservative policy helper: reject close-delimited HTTPS responses
    because the an adapter cannot distinguish authenticated TLS closure from raw
    EOF. The native clients now preserve this distinction and do not use this
    helper. Explicit framing and bodyless statuses remain supported. This check
    assumes a validated final response from the engine. *)

type endpoint = private {
  host : string;
  port : int;
  tls : bool;
  request : unit Request.t;
}

type framing = [ `Empty | `Fixed of int64 | `Chunked ]

val same_origin : endpoint -> endpoint -> bool
(** Scheme, case-insensitive hostname and effective port; never redirects. *)

val prepare :
  ?headers:Headers.t ->
  ?meth:Method.t ->
  ?body:framing ->
  ?keep_alive:bool ->
  string ->
  (endpoint, string) result

(** Validate an absolute HTTP/HTTPS URL and construct an origin-form request
    (GET by default), owning Host and body framing. Connection: close is the
    default; keep_alive permits pool reuse. Only
    GET/HEAD/POST/PUT/PATCH/DELETE/OPTIONS are supported; HEAD cannot upload a
    body. Reject userinfo, fragments, raw whitespace, non-ASCII bytes,
    backslashes and caller-supplied framing/connection fields. URL parsing does
    not authorize a destination: applications accepting untrusted URLs must
    enforce their own destination/network access policy. *)

val check_timeout : float -> unit
(** Reject nonpositive, infinite and NaN deadlines before opening a connection.
*)

exception Tls_truncated
(** Raw transport EOF before an authenticated TLS close_notify. *)
