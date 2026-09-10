module M = Http_kit_middleware
type anonymous = Anonymous
type authenticated = Authenticated of string
let endpoint (Authenticated name) (_ : unit Http_kit_core.Request.t) = name
let invalid : (anonymous, unit, string) M.Context.handler =
  M.Indexed.identity endpoint
