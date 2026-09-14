(** Private metadata-seam prototype, not a public protocol implementation.
    Parsing and protocol-specific field validation remain backend obligations.
*)
type protocol = Http1 of Httpkit_core.Version.t | Http2 | Http3

type t

val of_http1 :
  scheme:string -> authority:string -> 'a Httpkit_core.Request.t -> t

val of_http2 : H2.Request.t -> (t, Httpkit_core.Error.t) result
val protocol : t -> protocol
val meth : t -> Httpkit_core.Method.t
val target : t -> Httpkit_core.Target.t
val scheme : t -> string
val authority : t -> string
val headers : t -> Httpkit_core.Headers.t
