(* Shared application code: no native runtime or transport types. *)
open Http_kit_core
module R = Http_kit_router
module M = Http_kit_middleware

let response ?(headers = []) status body =
  let headers =
    Result.get_ok
      (Headers.of_list
         (("content-length", string_of_int (String.length body)) :: headers))
  in
  Response.create ~status:(Result.get_ok (Status.of_int status)) ~headers body

let route meth path handler =
  R.route ~meth (Result.get_ok (R.pattern path)) handler

let routes =
  Result.get_ok
    (R.compile
       [
         route Method.get "/" (fun _ _ -> response 200 "Hello /\n");
         route Method.get "/users/me" (fun _ _ -> response 200 "Current user\n");
         route Method.get "/users/:id" (fun params _ ->
             response 200
               ("User " ^ Option.get (R.Params.find "id" params) ^ "\n"));
         route Method.get "/files/*path" (fun params _ ->
             response 200
               ("Raw path: " ^ Option.get (R.Params.find "path" params) ^ "\n"));
         route Method.post "/echo" (fun _ request ->
             response 200 (Request.body request));
       ])

let dispatch request =
  match
    R.lookup routes ~meth:(Request.meth request)
      ~target:(Request.target request)
  with
  | Ok (R.Matched matched) -> matched.value matched.params request
  | Ok R.Not_found -> response 404 "Not found\n"
  | Ok (R.Method_not_allowed methods) ->
      let allow = String.concat ", " (List.map Method.to_string methods) in
      response ~headers:[ ("allow", allow) ] 405 "Method not allowed\n"
  | Error _ -> response 400 "Unsupported or oversized routing target\n"

let handle =
  let tag next request =
    let r = next request in
    let header = Result.get_ok (Header.of_strings "x-example" "http-kit") in
    Response.with_headers
      (Result.get_ok (Headers.add header (Response.headers r)))
      r
  in
  M.Basic.chain [ tag ] dispatch
