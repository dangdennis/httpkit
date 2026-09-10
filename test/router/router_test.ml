open Http_kit_core
module R = Http_kit_router

let ok = Result.get_ok
let route meth path value = R.route ~meth (ok (R.pattern path)) value

let find ?(meth = Method.get) table path =
  R.lookup table ~meth ~target:(ok (Target.of_string path))

let matched result value params =
  match result with
  | Ok (R.Matched m) ->
      assert (m.value = value);
      assert (R.Params.to_list m.params = params)
  | _ -> assert false

let precedence () =
  let routes =
    [
      route Method.get "/users/me" 1;
      route Method.get "/users/:id" 2;
      route Method.post "/users/:id" 3;
      route Method.get "/files/*rest" 4;
    ]
  in
  let table = ok (R.compile routes) in
  matched (find table "/users/me") 1 [];
  matched (find table "/users/123?view=full") 2 [ ("id", "123") ];
  matched (find ~meth:Method.post table "/users/me") 3 [ ("id", "me") ];
  matched (find table "/files/a/b") 4 [ ("rest", "a/b") ];
  matched (find table "/files") 4 [ ("rest", "") ];
  matched (find table "/files/") 4 [ ("rest", "") ];
  assert (find table "/users/" = Ok R.Not_found);
  matched
    (find (ok (R.compile (List.rev routes))) "/users/me")
    2
    [ ("id", "me") ]

let methods () =
  let table =
    ok
      (R.compile
         [
           route Method.get "/:id" 1;
           route Method.post "/x" 2;
           route Method.get "/x" 3;
         ])
  in
  assert (
    find ~meth:Method.put table "/x"
    = Ok (R.Method_not_allowed [ Method.get; Method.post ]));
  assert (
    find ~meth:Method.head table "/x"
    = Ok (R.Method_not_allowed [ Method.get; Method.post ]));
  assert (
    find ~meth:(ok (Method.of_string "get")) table "/x"
    = Ok (R.Method_not_allowed [ Method.get; Method.post ]));
  assert (find table "/x/y" = Ok R.Not_found)

let raw_paths () =
  let table =
    ok
      (R.compile
         [
           route Method.get "/x/:id" 1;
           route Method.get "/a//b/" 2;
           route Method.get "/" 3;
         ])
  in
  List.iter
    (fun id -> matched (find table ("/x/" ^ id)) 1 [ ("id", id) ])
    [ "%2f"; "%2F"; ".."; "%2e%2e"; "a+b"; "%3F" ];
  matched (find table "/a//b/") 2 [];
  assert (find table "/a/b/" = Ok R.Not_found);
  assert (find table "/a//b" = Ok R.Not_found);
  matched (find table "/?query=/a/b") 3 [];
  List.iter
    (fun target -> assert (find table target = Error R.Unsupported_target))
    [ "*"; "example.com:443"; "http://example.com/x" ]

let patterns () =
  List.iter
    (fun text -> assert (R.pattern text = Error R.Invalid_pattern))
    [
      "";
      "x";
      "/:";
      "/*";
      "/:1x";
      "/:a/:a";
      "/:a/*a";
      "/*a/b";
      "/a?b";
      "/%zz";
      "/a b";
      "/:a-b";
    ];
  assert (R.pattern ~max_bytes:0 "/" = Error R.Invalid_limit);
  assert (R.pattern ~max_segments:0 "/" = Error R.Invalid_limit);
  assert (Result.is_ok (R.pattern ~max_bytes:2 "/a"));
  assert (R.pattern ~max_bytes:1 "/a" = Error R.Invalid_pattern);
  assert (R.pattern ~max_segments:1 "/a/b" = Error R.Segment_limit)

let limits () =
  let one = route Method.get "/x" () in
  assert (R.compile ~max_routes:0 [ one ] = Error R.Too_many_routes);
  assert (Result.is_ok (R.compile ~max_routes:0 []));
  assert (R.compile ~max_routes:(-1) [] = Error R.Invalid_limit);
  assert (R.compile ~max_target_bytes:(-1) [] = Error R.Invalid_limit);
  assert (R.compile ~max_segments:(-1) [] = Error R.Invalid_limit);
  let table = ok (R.compile ~max_target_bytes:2 [ one ]) in
  matched (find table "/x") () [];
  assert (find table "/x?" = Error R.Target_limit);
  let table = ok (R.compile ~max_segments:1 [ one ]) in
  assert (find table "/x/y" = Error R.Segment_limit);
  let table = ok (R.compile ~max_segments:0 [ route Method.get "/" () ]) in
  matched (find table "/") () [];
  assert (find table "/x" = Error R.Segment_limit)

let isolation () =
  let a = ok (R.compile [ route Method.get "/:a" 1 ]) in
  let b = ok (R.compile [ route Method.get "/:b" 2 ]) in
  matched (find a "/value") 1 [ ("a", "value") ];
  matched (find b "/value") 2 [ ("b", "value") ];
  matched (find a "/other") 1 [ ("a", "other") ];
  match find a "/value" with
  | Ok (R.Matched m) ->
      assert (R.Params.find "a" m.params = Some "value");
      assert (R.Params.find "b" m.params = None)
  | _ -> assert false

let generated () =
  (* Independent exact-match oracle: percent spellings are opaque and unique
     literal paths must select their declaration, regardless of query bytes. *)
  let routes =
    List.init 100 (fun n -> route Method.get ("/items/" ^ string_of_int n) n)
  in
  let table = ok (R.compile routes) in
  let property =
    QCheck.Test.make ~count:1000 ~name:"literal selection and query isolation"
      QCheck.(int_range 0 199)
      (fun n ->
        match find table ("/items/" ^ string_of_int n ^ "?ignored=/") with
        | Ok (R.Matched m) ->
            n < 100 && m.value = n && R.Params.to_list m.params = []
        | Ok R.Not_found -> n >= 100
        | _ -> false)
  in
  QCheck.Test.check_exn ~rand:(Random.State.make [| 42 |]) property

let () =
  Alcotest.run "router"
    [
      ( "matching",
        List.map
          (fun (name, f) -> Alcotest.test_case name `Quick f)
          [
            ("declaration order and captures", precedence);
            ("405 method union", methods);
            ("raw path preservation", raw_paths);
            ("pattern rejection", patterns);
            ("exact limits", limits);
            ("table isolation", isolation);
            ("generated literal oracle", generated);
          ] );
    ]
