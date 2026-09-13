open Httpkit_core
module M = Httpkit_middleware

type anonymous = { token : string }
type authenticated = { user : string }
type authorized = { account : string }

let request =
  Request.create ~meth:Method.get
    ~target:(Result.get_ok (Target.of_string "/account"))
    ()

let response body = Response.create ~status:Status.ok body

(* Style 1: ordinary functions. No extra context argument is required. *)
let basic =
  let decorate next request =
    let response = next request in
    Response.map_body String.uppercase_ascii response
  in
  M.Basic.chain [ decorate ] (fun _ -> response "public")

(* Style 2: all wrappers agree on a context record. *)
let contextual =
  let decorate next (context : authenticated) request =
    let response = next context request in
    Response.map_body (fun body -> context.user ^ ": " ^ body) response
  in
  M.Context.chain [ decorate ] (fun _ _ -> response "account")

(* Style 3: each step declares which context it accepts and produces.
   The literal token below is a demonstration fixture, not authentication code. *)
let authenticate =
  M.Transition.guard
    (fun (context : anonymous) _ ->
      if context.token = "demo" then Ok { user = "Ada" } else Error ())
    ~reject:(fun () ->
      Response.create ~status:(Result.get_ok (Status.of_int 401)) "unauthorized")

let authorize =
  M.Transition.map_context (fun (context : authenticated) ->
      { account = context.user ^ "'s account" })

let protected =
  M.Transition.compose authenticate authorize (fun (context : authorized) _ ->
      response context.account)

let () =
  assert (Response.body (basic request) = "PUBLIC");
  assert (Response.body (contextual { user = "Ada" } request) = "Ada: account");
  assert (Response.body (protected { token = "demo" } request) = "Ada's account");
  assert (
    Status.to_int (Response.status (protected { token = "bad" } request)) = 401);
  print_endline "PASS: basic, contextual and transition middleware"
