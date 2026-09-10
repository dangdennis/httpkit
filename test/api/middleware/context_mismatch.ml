module M = Http_kit_middleware
let context : (string, unit, int) M.Context.t = fun next c r -> next c r
let endpoint (count : int) (_ : unit Http_kit_core.Request.t) = count
let invalid = context endpoint
