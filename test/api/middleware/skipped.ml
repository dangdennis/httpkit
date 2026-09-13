module M = Httpkit_middleware
type anonymous = Anonymous
type authenticated = Authenticated of string
let endpoint (Authenticated name) (_ : unit Httpkit_core.Request.t) = name
let invalid : (anonymous, unit, string) M.Context.handler =
  M.Transition.identity endpoint
