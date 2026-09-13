val bearer : Httpkit_core.Headers.t -> (string option, string) result
(** Reject duplicate Authorization fields and malformed bearer credentials. *)

val authenticate :
  verify:(string -> 'a option) ->
  Httpkit_core.Headers.t ->
  ('a option, string) result

val csrf :
  allowed_origins:string list ->
  token_valid:(string -> bool) ->
  meth:Httpkit_core.Method.t ->
  Httpkit_core.Headers.t ->
  bool
(** Unsafe methods require one exact allowlisted Origin and one valid
    X-CSRF-Token. *)
