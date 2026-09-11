open Http_kit_core
module M = Http_kit_middleware

let request =
  Request.create ~meth:Method.get
    ~target:(Result.get_ok (Target.of_string "/"))
    (ref 0)

let order () =
  let calls = ref [] in
  let record x = calls := !calls @ [ x ] in
  let layer name next r =
    record (name ^ " before");
    let result = next r in
    record (name ^ " after");
    result
  in
  let endpoint r =
    assert (r == request);
    record "endpoint";
    7
  in
  let h = M.Basic.chain [ layer "a"; layer "b" ] endpoint in
  assert (h request = 7);
  assert (!calls = [ "a before"; "b before"; "endpoint"; "b after"; "a after" ]);
  assert (M.Basic.chain [] endpoint request = 7)

let context () =
  let seen = ref [] in
  let layer delta next context request =
    seen := context :: !seen;
    next (context + delta) request
  in
  let h =
    M.Context.chain
      [ layer 1; layer 2 ]
      (fun c r ->
        assert (r == request);
        c)
  in
  assert (h 10 request = 13);
  assert (!seen = [ 11; 10 ]);
  assert (M.Context.chain [] (fun c _ -> c) 9 request = 9)

let guards () =
  let decisions = ref 0 and endpoints = ref 0 and rejected = ref 0 in
  let guard =
    M.Transition.guard
      (fun number r ->
        assert (r == request);
        incr decisions;
        if number > 0 then Ok (string_of_int number) else Error "denied")
      ~reject:(fun error ->
        incr rejected;
        Error error)
  in
  let length = M.Transition.map_context String.length in
  let h =
    M.Transition.compose guard length (fun size r ->
        assert (r == request);
        incr endpoints;
        Ok size)
  in
  assert (h 123 request = Ok 3);
  assert (h 0 request = Error "denied");
  assert (!decisions = 2 && !endpoints = 1 && !rejected = 1);
  assert (!(Request.body request) = 0)

exception Expected

let exceptions () =
  let intercepted = ref false in
  let guard =
    M.Transition.guard
      (fun () _ -> raise Expected)
      ~reject:(fun () -> intercepted := true)
  in
  (try
     guard (fun () _ -> assert false) () request;
     assert false
   with Expected -> ());
  assert (not !intercepted)

let native_result () =
  (* An opaque deferred result is carried through without forcing or mapping it.
     Native promise types can occupy the same output position. *)
  let forced = ref false in
  let result =
    lazy
      (forced := true;
       42)
  in
  let layer next r = next r in
  assert (M.Basic.chain [ layer ] (fun _ -> result) request == result);
  assert (not !forced);
  let lifted = M.Transition.lift (fun next c r -> next (c + 1) r) in
  assert (lifted (fun c _ -> c) 0 request = 1)

let () =
  Alcotest.run "middleware"
    [
      ( "composition",
        List.map
          (fun (name, f) -> Alcotest.test_case name `Quick f)
          [
            ("nesting and identity", order);
            ("typed context", context);
            ("guard short circuit and transition", guards);
            ("exceptions propagate", exceptions);
            ("native result and lifting", native_result);
          ] );
    ]
