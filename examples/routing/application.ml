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

let capture name params =
  match R.Params.find name params with
  | Some value -> value
  | None -> invalid_arg ("route is missing declared capture: " ^ name)

let routes =
  Result.get_ok
    (R.compile
       [
         route Method.get "/" (fun _ _ -> response 200 "Hello /\n");
         route Method.get "/protected" (fun _ _ ->
             response 401 "Demo identity required\n");
         route Method.get "/users/me" (fun _ _ -> response 200 "Current user\n");
         route Method.get "/users/:id" (fun params _ ->
             response 200 ("User " ^ capture "id" params ^ "\n"));
         route Method.get "/files/*path" (fun params _ ->
             response 200 ("Raw path: " ^ capture "path" params ^ "\n"));
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

(* Head policy runs before body collection: a waiting client needs permission,
   while a route rejection can be sent immediately without accepting its upload. *)
let expects_continue request =
  Headers.get_all
    (Result.get_ok (Header.Name.of_string "expect"))
    (Request.headers request)
  <> []

let upload_policy request =
  match
    R.lookup routes ~meth:(Request.meth request)
      ~target:(Request.target request)
  with
  | Ok (R.Matched _) -> `Consume
  | _ -> `Reject (handle (Request.with_body "" request))

let continue_response =
  Response.create ~status:(Result.get_ok (Status.of_int 100)) ()

(* Demo context only: this header is not a production authentication protocol. *)
type authenticated = { name : string }

let authenticate request =
  match
    Headers.get_all
      (Result.get_ok (Header.Name.of_string "x-demo-user"))
      (Request.headers request)
  with
  | [ value ] when Header.Value.to_string value = "demo" ->
      Some { name = "demo" }
  | _ -> None

let protected user _request =
  response
    ~headers:[ ("x-example", "http-kit") ]
    200
    ("Hello " ^ user.name ^ "\n")

let denied () =
  response ~headers:[ ("x-example", "http-kit") ] 401 "Demo identity required\n"

let is_protected request =
  Target.to_string (Request.target request) = "/protected"
