open Http_kit_core
open Suite_support
module R = Http_kit_router

let target = fun s -> ok (Target.of_string s)
let make_route path value = R.route ~meth:Method.get (ok (R.pattern path)) value

let jobs () =
  let patterns =
    [
      ("literal", "/users/me");
      ("parameter", "/users/:id");
      ("wildcard", "/files/*path");
    ]
  in
  List.map
    (fun (name, p) ->
      job "router" ("pattern/" ^ name) 3000 (fun () ->
          require (Result.is_ok (R.pattern p))))
    patterns
  @ List.concat_map
      (fun count ->
        let routes =
          List.init count (fun n ->
              make_route ("/group" ^ string_of_int n ^ "/:id") n)
        in
        let table = ok (R.compile routes) in
        let compile =
          job "router" (Printf.sprintf "compile/%d" count) 500 (fun () ->
              require (Result.is_ok (R.compile routes)))
        in
        let probes =
          [
            ("first", Method.get, "/group0/value", `Match 0);
            ( "middle",
              Method.get,
              "/group" ^ string_of_int (count / 2) ^ "/value",
              `Match (count / 2) );
            ( "last",
              Method.get,
              "/group" ^ string_of_int (count - 1) ^ "/value",
              `Match (count - 1) );
            ("missing", Method.get, "/absent/value", `Missing);
            ("method", Method.post, "/group0/value", `Method);
          ]
        in
        compile
        :: List.map
             (fun (name, meth, path, expected) ->
               let target = target path in
               job "router" (Printf.sprintf "lookup/%d/%s" count name) 1000
                 (fun () ->
                   match (R.lookup table ~meth ~target, expected) with
                   | Ok (R.Matched m), `Match n ->
                       require
                         (m.value = n
                         && R.Params.find "id" m.params = Some "value")
                   | Ok R.Not_found, `Missing -> ()
                   | Ok (R.Method_not_allowed [ m ]), `Method ->
                       require (Method.equal m Method.get)
                   | _ -> failwith "router benchmark selected the wrong outcome"))
             probes)
      [ 10; 100; 1000 ]
  @ List.map
      (fun (name, pattern, path, capture) ->
        let table = ok (R.compile [ make_route pattern () ]) in
        let target = target path in
        job "router" ("shape/" ^ name) 5000 (fun () ->
            match R.lookup table ~meth:Method.get ~target with
            | Ok (R.Matched m) -> require (R.Params.to_list m.params = capture)
            | _ -> failwith "router shape mismatch"))
      [
        ("literal", "/users/me", "/users/me", []);
        ("parameter", "/users/:id", "/users/123", [ ("id", "123") ]);
        ("wildcard", "/files/*path", "/files/a/b/c", [ ("path", "a/b/c") ]);
        ("wildcard-empty", "/files/*path", "/files", [ ("path", "") ]);
        ( "encoded-query",
          "/users/:id",
          "/users/%2F?q=/ignored",
          [ ("id", "%2F") ] );
        ("deep", "/a/b/c/d/e/f/:id", "/a/b/c/d/e/f/123", [ ("id", "123") ]);
      ]
