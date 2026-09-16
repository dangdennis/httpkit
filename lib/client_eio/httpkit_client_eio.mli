(** Scoped streaming HTTP/1.1 GET over HTTP or verified HTTPS. Initialize an
    upstream Mirage_crypto_rng generator before HTTPS. The authenticator should
    normally come from Ca_certs.authenticator; there is no insecure default. *)

type body

val read : body -> string option
(** One bounded chunk, or None at complete HTTP framing. Read only inside the
    response callback, with one reader. Premature EOF raises the adapter error.
    No automatic decompression. No body accumulation or implicit draining. *)

val trailers : body -> Httpkit_core.Headers.t option
(** Available after read returns None, including an empty collection. *)

val with_response :
  ?headers:Httpkit_core.Headers.t ->
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
    pooling, retries, proxy discovery, cookies, uploads or protocol handoff. TLS
    offers HTTP/1.1 only and verifies the URL hostname/IP with the supplied
    authenticator. Invalid input raises Invalid_argument before networking.
    Close-delimited HTTPS raises Httpkit_client.Unframed_https_response.
    Teardown attempts a closure alert with a separate one-second limit.
    Network/TLS/runtime exceptions propagate; HTTP failures use
    Httpkit_transport_eio.Error. *)
