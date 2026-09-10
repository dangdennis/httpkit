(** Handler wrappers with increasing context guarantees.

    These combinators perform no I/O, schedule no work, catch no exceptions and
    own no request bodies. The result type is unconstrained: it can be a
    response, an application result, or a runtime-specific promise.

    Composition is outermost first: [compose a b endpoint] means
    [a (b endpoint)]. Wrappers may short-circuit. OCaml does not enforce linear
    use of [next]; the application must not call a one-shot endpoint more than
    once. *)

module Basic : sig
  type ('body, 'output) handler = 'body Http_kit_core.Request.t -> 'output
  type ('body, 'output) t = ('body, 'output) handler -> ('body, 'output) handler

  val identity : ('body, 'output) t
  val compose : ('body, 'output) t -> ('body, 'output) t -> ('body, 'output) t

  val chain : ('body, 'output) t list -> ('body, 'output) t
  (** Homogeneous wrappers, in declaration order. An empty chain is identity.
      This style carries no context requirement in the endpoint's type. *)
end

module Context : sig
  type ('context, 'body, 'output) handler =
    'context -> 'body Http_kit_core.Request.t -> 'output

  type ('context, 'body, 'output) t =
    ('context, 'body, 'output) handler -> ('context, 'body, 'output) handler

  val identity : ('context, 'body, 'output) t

  val compose :
    ('context, 'body, 'output) t ->
    ('context, 'body, 'output) t ->
    ('context, 'body, 'output) t

  val chain : ('context, 'body, 'output) t list -> ('context, 'body, 'output) t
  (** Every wrapper and endpoint agrees on one context type. Use an application
      record or object; there is no untyped field bag or global context. This
      style does not prove that an optional field has been populated. *)
end

module Indexed : sig
  type ('before, 'after, 'body, 'output) t =
    ('after, 'body, 'output) Context.handler ->
    ('before, 'body, 'output) Context.handler
  (** A context transition. For example, a wrapper can accept an anonymous
      context and supply an authenticated context to its continuation. The
      context types are chosen and constructed by the application. *)

  val identity : ('context, 'context, 'body, 'output) t

  val compose :
    ('a, 'b, 'body, 'output) t ->
    ('b, 'c, 'body, 'output) t ->
    ('a, 'c, 'body, 'output) t
  (** Adjacent context types must agree. Unlike [Basic.chain], heterogeneous
      transitions compose pairwise, not through a homogeneous list. *)

  val lift :
    ('context, 'body, 'output) Context.t ->
    ('context, 'context, 'body, 'output) t
  (** Reuse a context-preserving wrapper without losing its type information. *)

  val map_context : ('before -> 'after) -> ('before, 'after, 'body, 'output) t
  (** Derive the next context once per request, preserving the request value. *)

  val guard :
    ('before -> 'body Http_kit_core.Request.t -> ('after, 'error) result) ->
    reject:('error -> 'output) ->
    ('before, 'after, 'body, 'output) t
  (** A synchronous decision: call [next] once on [Ok], or [reject] once on
      [Error]. No exception is converted into a rejection. For asynchronous
      decisions, write an indexed wrapper using the runtime's native bind.

      The types enforce context plumbing, not the truth of authentication or
      authorization. Abstract application context types can restrict who is
      allowed to construct an authenticated value. *)
end
