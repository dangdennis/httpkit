open Httpkit_core

exception Unframed_https_response

val check_response : tls:bool -> unit Response.t -> unit
(** Strict GET-client policy: reject close-delimited HTTPS responses because the
    current upstream TLS adapters do not distinguish an authenticated closure
    alert from raw transport EOF. Explicit framing and bodyless statuses remain
    supported. This check assumes a validated final response from the engine. *)

type endpoint = private {
  host : string;
  port : int;
  tls : bool;
  request : unit Request.t;
}

val prepare : ?headers:Headers.t -> string -> (endpoint, string) result
(** Validate an absolute HTTP/HTTPS URL and construct an origin-form GET with
    Host and Connection: close. Reject userinfo, fragments, raw whitespace,
    non-ASCII bytes, backslashes and caller-supplied framing/connection fields.
    URL parsing does not authorize a destination: applications accepting
    untrusted URLs must enforce their own destination/network access policy. *)

val check_timeout : float -> unit
(** Reject nonpositive, infinite and NaN deadlines before opening a connection.
*)
