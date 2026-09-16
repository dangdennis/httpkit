(** Scoped native Lwt streaming HTTP client. Initialize an upstream
    Mirage_crypto_rng generator before HTTPS; use a verifying authenticator,
    normally Ca_certs.authenticator. No insecure default. *)

type upload

val upload : ?length:int64 -> (unit -> string option Lwt.t) -> upload
(** Single-use pull producer. With [length], emit exactly that many bytes;
    otherwise chunked framing is generated. Chunks must be nonempty and at most
    65536 bytes. The producer runs after TLS authentication, concurrently with
    response receipt, and is cancelled and joined on early final response.
    Producers and their finalizers must cooperate with runtime cancellation. *)

type body

val read : body -> string option Lwt.t
(** One bounded chunk, or None after complete HTTP framing. Single reader,
    usable only inside the callback. Premature EOF raises the adapter error. *)

val trailers : body -> Httpkit_core.Headers.t option
(** Available after read returns None, including an empty collection. *)

val with_response :
  ?headers:Httpkit_core.Headers.t ->
  ?meth:Httpkit_core.Method.t ->
  ?upload:upload ->
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
    redirects, retries, proxies, cookies, decompression or protocol handoff.
    HTTPS offers HTTP/1.1 and authenticates the URL hostname/IP. Invalid input
    fails before networking. HTTP errors use Httpkit_transport_lwt.Error;
    network/TLS/runtime exceptions propagate. Close-delimited HTTPS completes
    only on authenticated TLS close_notify. Raw TLS EOF raises
    Httpkit_client.Tls_truncated (wrapped in the transport error during response
    reads). TLS teardown has a separate one-second closure-alert allowance. *)

exception Pool_exhausted

type pool

val with_pool :
  ?max_connections:int ->
  ?idle_timeout:float ->
  ?policy:Httpkit_engine.Timeout.policy ->
  ?limits:Httpkit_http1.limits ->
  authenticator:X509.Authenticator.t ->
  string ->
  (pool -> 'a Lwt.t) ->
  'a Lwt.t
(** Origin-scoped pool; default four connections, at most 1024. No waiting
    queue: simultaneous requests beyond the cap fail with Pool_exhausted. Idle
    entries expire after 30s by default, checked when borrowed. The scope
    cancels and joins outstanding requests and closes all idle connections on
    exit. *)

val request :
  pool ->
  ?headers:Httpkit_core.Headers.t ->
  ?meth:Httpkit_core.Method.t ->
  ?upload:upload ->
  ?timeout:float ->
  string ->
  (unit Httpkit_core.Response.t -> body -> 'a Lwt.t) ->
  'a Lwt.t
(** Same-origin request with the pool's authenticator and immutable
    policy/limits. Reuse requires complete consumption and flushed output.
    Abandonment, errors and cancellation close the connection. Stale connections
    fail without replay. No pipelining; one runtime thread/domain owns the pool.
*)
