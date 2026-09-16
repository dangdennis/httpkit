(** Scoped native Lwt streaming GET client. Initialize an upstream
    Mirage_crypto_rng generator before HTTPS; use a verifying authenticator,
    normally Ca_certs.authenticator. No insecure default. *)

type body

val read : body -> string option Lwt.t
(** One bounded chunk, or None after complete HTTP framing. Single reader,
    usable only inside the callback. Premature EOF raises the adapter error. *)

val trailers : body -> Httpkit_core.Headers.t option
(** Available after read returns None, including an empty collection. *)

val with_response :
  ?headers:Httpkit_core.Headers.t ->
  ?timeout:float ->
  ?policy:Httpkit_engine.Timeout.policy ->
  ?limits:Httpkit_http1.limits ->
  authenticator:X509.Authenticator.t ->
  string ->
  (unit Httpkit_core.Response.t -> body -> 'a Lwt.t) ->
  'a Lwt.t
(** Default total deadline 30s includes DNS, connect, TLS, response and
    callback. Cancellation and timeout cancel and join owned work before
    returning. Callbacks must cooperate with cancellation; finalizers must
    terminate. Each call closes its connection on return/error/cancellation; no
    implicit draining. Final statuses are returned unchanged. No pooling,
    redirects, retries, proxies, cookies, decompression, uploads or protocol
    handoff. HTTPS offers HTTP/1.1 and authenticates the URL hostname/IP.
    Invalid input fails before networking. HTTP errors use
    Httpkit_transport_lwt.Error; network/TLS/runtime exceptions propagate.
    Close-delimited HTTPS raises Httpkit_client.Unframed_https_response. TLS
    teardown has a separate one-second closure-alert allowance. *)
