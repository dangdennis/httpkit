module M = Httpkit_middleware
let first = M.Transition.map_context (fun (x : int) -> string_of_int x)
let second = M.Transition.map_context (fun (x : string) -> String.length x > 0)
let invalid = M.Transition.compose second first
