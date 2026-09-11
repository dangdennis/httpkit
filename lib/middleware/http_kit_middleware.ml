module Basic = struct
  type ('body, 'output) handler = 'body Http_kit_core.Request.t -> 'output
  type ('body, 'output) t = ('body, 'output) handler -> ('body, 'output) handler

  let identity next = next
  let compose outer inner next = outer (inner next)
  let chain wrappers = List.fold_right compose wrappers identity
end

module Context = struct
  type ('context, 'body, 'output) handler =
    'context -> 'body Http_kit_core.Request.t -> 'output

  type ('context, 'body, 'output) t =
    ('context, 'body, 'output) handler -> ('context, 'body, 'output) handler

  let identity next = next
  let compose outer inner next = outer (inner next)
  let chain wrappers = List.fold_right compose wrappers identity
end

module Transition = struct
  type ('before, 'after, 'body, 'output) t =
    ('after, 'body, 'output) Context.handler ->
    ('before, 'body, 'output) Context.handler

  let identity next = next
  let compose outer inner next = outer (inner next)
  let lift middleware = middleware
  let map_context f next context request = next (f context) request

  (* Only this helper promises single invocation. Arbitrary caller-supplied
     wrappers retain responsibility for their continuation and body lifetime. *)
  let guard decide ~reject next context request =
    match decide context request with
    | Ok context -> next context request
    | Error error -> reject error
end
