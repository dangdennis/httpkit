(* The same pure handler is linked by both runtime examples. It consumes only
   validated request metadata and owns the body value it returns. *)
open Httpkit_core

let handle request =
  let body = "Hello " ^ Target.to_string (Request.target request) ^ "\n" in
  let headers =
    Result.get_ok
      (Headers.of_list
         [ ("content-length", string_of_int (String.length body)) ])
  in
  Response.create ~status:Status.ok ~headers body
