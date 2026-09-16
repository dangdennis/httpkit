(** Scoped streaming HTTP/1.1 requests over HTTP or verified HTTPS. Initialize
    an upstream Mirage_crypto_rng generator before HTTPS. The authenticator
    should normally come from Ca_certs.authenticator; there is no insecure
    default. *)

type upload

val upload : ?length:int64 -> (unit -> string option) -> upload
(** Single-use pull producer. With [length], emit exactly that many bytes;
    otherwise chunked framing is generated. Chunks must be nonempty and at most
    65536 bytes. The producer runs after TLS authentication, concurrently with
    response receipt, and is cancelled and joined on early final response.
    Producers and their finalizers must cooperate with runtime cancellation. *)

type body

val read : body -> string option
(** One bounded chunk, or None at complete HTTP framing. Read only inside the
    response callback, with one reader. Premature EOF raises the adapter error.
    No automatic decompression. No body accumulation or implicit draining. *)

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
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.Mono.t ->
  string ->
  (unit Httpkit_core.Response.t -> body -> 'a) ->
  'a
(** Default total deadline 30s covers DNS, connect, TLS, response and callback.
    The callback must cooperate with cancellation. Each call owns one
    connection, closed on return, exception or cancellation; an unread body is
    abandoned. Returns all final statuses without following redirects. No
    automatic retries, proxy discovery, cookies or protocol handoff. TLS offers
    HTTP/1.1 only and verifies the URL hostname/IP with the supplied
    authenticator. Invalid input raises Invalid_argument before networking.
    Close-delimited HTTPS completes only on authenticated TLS close_notify. Raw
    TLS EOF raises Httpkit_client.Tls_truncated (wrapped in the transport error
    during response reads). Teardown attempts a closure alert with a separate
    one-second limit. Network/TLS/runtime exceptions propagate; HTTP failures
    use Httpkit_transport_eio.Error. *)

exception Pool_exhausted

type pool

val with_pool :
  ?max_connections:int ->
  ?idle_timeout:float ->
  ?policy:Httpkit_engine.Timeout.policy ->
  ?limits:Httpkit_http1.limits ->
  authenticator:X509.Authenticator.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.Mono.t ->
  string ->
  (pool -> 'a) ->
  'a
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
  (unit Httpkit_core.Response.t -> body -> 'a) ->
  'a
(** Same-origin request with the pool's authenticator and immutable
    policy/limits. Reuse requires complete consumption and flushed output.
    Abandonment, errors and cancellation close the connection. Stale connections
    fail without replay. No pipelining; one runtime thread/domain owns the pool.
*)
