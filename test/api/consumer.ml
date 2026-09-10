open Http_kit_core

let ( let* ) = Result.bind

(* This is the public documentation example, compiled against installed files. *)
let request path =
  let* target = Target.of_string path in
  let* headers = Headers.of_list [ ("accept", "application/json") ] in
  Ok (Request.create ~meth:Method.get ~target ~headers ())

let () =
  match request "/items?cursor=a%2Fb" with
  | Error e -> failwith (Error.to_string e)
  | Ok request ->
      let request : string Request.t =
        Request.map_body (fun () -> "payload") request
      in
      assert (Request.body request = "payload");
      assert (Target.to_string (Request.target request) = "/items?cursor=a%2Fb");
      let response : unit Response.t = Response.create ~status:Status.ok () in
      let response : int Response.t = Response.with_body 42 response in
      assert (Response.body response = 42);
      print_endline "PASS: installed core consumer"
