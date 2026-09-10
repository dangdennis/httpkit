open Http_kit_core
module R = Http_kit_router

let () =
  let pattern = Result.get_ok (R.pattern "/users/:id") in
  let routes =
    Result.get_ok (R.compile [ R.route ~meth:Method.get pattern "user" ])
  in
  let target = Result.get_ok (Target.of_string "/users/%2F") in
  (match R.lookup routes ~meth:Method.get ~target with
  | Ok (R.Matched m) ->
      assert (m.value = "user");
      assert (R.Params.find "id" m.params = Some "%2F")
  | _ -> assert false);
  assert (
    R.lookup routes ~meth:Method.post ~target
    = Ok (R.Method_not_allowed [ Method.get ]));
  print_endline "PASS: installed pure router"
