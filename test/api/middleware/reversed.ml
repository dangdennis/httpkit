module M = Http_kit_middleware
let first = M.Indexed.map_context (fun (x : int) -> string_of_int x)
let second = M.Indexed.map_context (fun (x : string) -> String.length x > 0)
let invalid = M.Indexed.compose second first
