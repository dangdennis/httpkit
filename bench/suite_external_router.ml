open Httpkit_core
open Suite_support
module R = Httpkit_router

(* Both adapters return the selected endpoint and its string capture. All timed
   lookups are GET on unambiguous valid paths. Routes has no HTTP method table;
   method mismatch/Allow and conflicting route precedence are not comparable. *)
let kit_lookup table path () =
  match ok (R.lookup table ~meth:Method.get ~target:path) with
  | R.Matched m ->
      Some (m.value, Option.value ~default:"" (R.Params.find "capture" m.params))
  | R.Not_found -> None
  | R.Method_not_allowed _ -> failwith "unexpected method mismatch"

let routes_lookup table path () =
  match Routes.match' table ~target:path with
  | Routes.FullMatch value -> Some value
  | Routes.NoMatch -> None
  | Routes.MatchWithTrailingSlash _ ->
      failwith "non-common trailing slash result"

let case workload implementation iterations work =
  job ~comparison:workload ~implementation "router"
    ("external/" ^ workload ^ "/" ^ implementation)
    iterations work

let routes_wildcard parts =
  let captured = Routes.Parts.wildcard_match parts in
  (* Routes includes the leading slash; normalize the public result to our
     common capture representation. This allocation is timed and disclosed. *)
  if captured = "" then ""
  else (
    require (captured.[0] = '/');
    String.sub captured 1 (String.length captured - 1))

let jobs () =
  let scaling =
    List.concat_map
      (fun count ->
        let definitions =
          List.init count (fun n ->
              let prefix = "group" ^ string_of_int n in
              let kit =
                R.route ~meth:Method.get
                  (ok (R.pattern ("/" ^ prefix ^ "/:capture")))
                  n
              in
              let routes =
                Routes.(
                  (s prefix / str /? nil) @--> fun capture -> (n, capture))
              in
              (kit, routes))
        in
        let kit_routes, routes_routes = List.split definitions in
        let kit_table = ok (R.compile kit_routes)
        and routes_table = Routes.one_of routes_routes in
        let initial = ok (Target.of_string "/group0/value") in
        let build =
          [
            case (Printf.sprintf "compile/%d" count) "httpkit" 100 (fun () ->
                let table = ok (R.compile kit_routes) in
                require (kit_lookup table initial () = Some (0, "value")));
            case (Printf.sprintf "compile/%d" count) "routes" 100 (fun () ->
                let table = Routes.one_of routes_routes in
                require
                  (routes_lookup table "/group0/value" () = Some (0, "value")));
          ]
        in
        let probes =
          [
            ("first", 0);
            ("middle", count / 2);
            ("last", count - 1);
            ("missing", count);
          ]
        in
        build
        @ List.concat_map
            (fun (name, index) ->
              let path = "/group" ^ string_of_int index ^ "/value" in
              let target = ok (Target.of_string path) in
              let expected =
                if index = count then None else Some (index, "value")
              in
              let workload = Printf.sprintf "lookup/%d/%s" count name in
              List.map
                (fun (implementation, lookup) ->
                  case workload implementation 5000 (fun () ->
                      require (lookup () = expected)))
                [
                  ("httpkit", kit_lookup kit_table target);
                  ("routes", routes_lookup routes_table path);
                ])
            probes)
      [ 10; 100; 1000 ]
  in
  let shapes =
    [
      ( "literal",
        "/users/me",
        Routes.((s "users" / s "me" /? nil) @--> (0, "")),
        "/users/me",
        "" );
      ( "parameter",
        "/users/:capture",
        Routes.((s "users" / str /? nil) @--> fun s -> (0, s)),
        "/users/123",
        "123" );
      ( "wildcard",
        "/files/*capture",
        Routes.((s "files" /? wildcard) @--> fun p -> (0, routes_wildcard p)),
        "/files/a/b/c",
        "a/b/c" );
      ( "wildcard-empty",
        "/files/*capture",
        Routes.((s "files" /? wildcard) @--> fun p -> (0, routes_wildcard p)),
        "/files",
        "" );
      ( "encoded-query",
        "/users/:capture",
        Routes.((s "users" / str /? nil) @--> fun s -> (0, s)),
        "/users/%2F?q=ignored",
        "%2F" );
    ]
  in
  scaling
  @ List.concat_map
      (fun (name, pattern, route, path, capture) ->
        let kit =
          ok (R.compile [ R.route ~meth:Method.get (ok (R.pattern pattern)) 0 ])
        in
        let routes = Routes.one_of [ route ] in
        let target = ok (Target.of_string path) in
        List.map
          (fun (implementation, lookup) ->
            case ("shape/" ^ name) implementation 5000 (fun () ->
                require (lookup () = Some (0, capture))))
          [
            ("httpkit", kit_lookup kit target);
            ("routes", routes_lookup routes path);
          ])
      shapes
