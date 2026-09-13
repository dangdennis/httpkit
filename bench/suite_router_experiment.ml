open Httpkit_core
open Suite_support
module R = Httpkit_router
module Prefixes = Map.Make (String)

type definition = {
  prefix : string option;
  literals : string list;
  route : int R.route;
}

type index = { fallback : int R.t; buckets : int R.t Prefixes.t; slots : int }

let first_segment text =
  if String.length text = 0 || text.[0] <> '/' then None
  else
    let rec finish i =
      if i = String.length text || text.[i] = '/' || text.[i] = '?' then i
      else finish (i + 1)
    in
    let stop = finish 1 in
    Some (String.sub text 1 (stop - 1))

let definition pattern meth value =
  let prefix =
    match first_segment pattern with
    | Some s when s <> "" && (s.[0] = ':' || s.[0] = '*') -> None
    | _ when pattern = "/" -> None
    | prefix -> prefix
  in
  let rec leading = function
    | [] -> []
    | s :: _ when s <> "" && (s.[0] = ':' || s.[0] = '*') -> []
    | s :: tail -> s :: leading tail
  in
  let literals =
    if pattern = "/" then []
    else
      leading
        (String.split_on_char '/'
           (String.sub pattern 1 (String.length pattern - 1)))
  in
  { prefix; literals; route = R.route ~meth (ok (R.pattern pattern)) value }

let reference definitions =
  ok (R.compile (List.map (fun d -> d.route) definitions))

(* Benchmark-only candidate index. Each bucket preserves original declaration
   order, including general routes, and delegates all matching/method/limit
   policy to the public reference router. A literal first segment cannot match
   a different first segment. General routes are deliberately duplicated: this
   prototype exposes the construction/memory tradeoff, not a production design. *)
let compile definitions =
  ignore (reference definitions);
  let prefixes =
    List.fold_left
      (fun acc d ->
        match d.prefix with None -> acc | Some key -> Prefixes.add key () acc)
      Prefixes.empty definitions
  in
  let general = List.filter (fun d -> d.prefix = None) definitions in
  let slots = ref (List.length general) in
  let buckets =
    Prefixes.mapi
      (fun key () ->
        let candidates =
          List.filter
            (fun d ->
              match d.prefix with
              | None -> true
              | Some expected -> String.equal expected key)
            definitions
        in
        slots := !slots + List.length candidates;
        reference candidates)
      prefixes
  in
  { fallback = reference general; buckets; slots = !slots }

let lookup index ~meth ~target =
  let table =
    match first_segment (Target.to_string target) with
    | None -> index.fallback
    | Some key ->
        Option.value ~default:index.fallback
          (Prefixes.find_opt key index.buckets)
  in
  R.lookup table ~meth ~target

(* Second experiment: store each route once at its longest literal prefix.
   Construction visits only the declared prefix segments. General routes stay
   at their ancestor node; lookup merges declaration ordinals before matching.
   Singleton reference tables deliberately retain the public matcher as oracle:
   this reparses targets for fallback candidates, a measured cost, not a proposed
   production implementation. No library internals or policy are copied here. *)
type node = {
  mutable children : node Prefixes.t;
  mutable routes : (int * int R.t) list;
}

type deep_index = { root : node; slots : int; nodes : int }

let empty_node () = { children = Prefixes.empty; routes = [] }

let compile_deep definitions =
  ignore (reference definitions);
  let root = empty_node () and nodes = ref 1 in
  List.iteri
    (fun ordinal d ->
      let rec insert node = function
        | [] -> node.routes <- (ordinal, reference [ d ]) :: node.routes
        | key :: tail ->
            let child =
              match Prefixes.find_opt key node.children with
              | Some child -> child
              | None ->
                  let child = empty_node () in
                  incr nodes;
                  node.children <- Prefixes.add key child node.children;
                  child
            in
            insert child tail
      in
      insert root d.literals)
    definitions;
  let rec finish node =
    node.routes <- List.rev node.routes;
    Prefixes.iter (fun _ child -> finish child) node.children
  in
  finish root;
  let slots = List.length definitions in
  require
    (!nodes
    <= 1 + List.fold_left (fun n d -> n + List.length d.literals) 0 definitions
    );
  { root; slots; nodes = !nodes }

let limit_oracle = reference []

let lookup_deep index ~meth ~target =
  (* Validate limits before splitting/indexing, including query bytes. *)
  match R.lookup limit_oracle ~meth ~target with
  | Error error -> Error error
  | Ok _ ->
      let text = Target.to_string target in
      let path =
        match String.index_opt text '?' with
        | None -> text
        | Some n -> String.sub text 0 n
      in
      let parts =
        if path = "/" then []
        else
          String.split_on_char '/' (String.sub path 1 (String.length path - 1))
      in
      let rec candidates node parts =
        match parts with
        | key :: tail -> (
            match Prefixes.find_opt key node.children with
            | None -> node.routes
            | Some child ->
                List.merge
                  (fun (a, _) (b, _) -> Int.compare a b)
                  node.routes (candidates child tail))
        | [] -> node.routes
      in
      let rec search allowed = function
        | [] ->
            Ok
              (if allowed = [] then R.Not_found
               else R.Method_not_allowed allowed)
        | (_, table) :: tail -> (
            match R.lookup table ~meth ~target with
            | Ok (R.Matched _ as matched) -> Ok matched
            | Ok (R.Method_not_allowed methods) ->
                let allowed =
                  List.fold_left
                    (fun acc m ->
                      if List.exists (Method.equal m) acc then acc
                      else acc @ [ m ])
                    allowed methods
                in
                search allowed tail
            | Ok R.Not_found -> search allowed tail
            | Error error -> Error error)
      in
      search [] (candidates index.root parts)

let check_equivalence () =
  let check definitions paths =
    let linear = reference definitions
    and indexed = compile definitions
    and deep = compile_deep definitions in
    require (deep.slots = List.length definitions);
    List.iter
      (fun path ->
        let target = ok (Target.of_string ~max_length:16384 path) in
        List.iter
          (fun meth ->
            require
              (R.lookup linear ~meth ~target = lookup indexed ~meth ~target);
            require
              (R.lookup linear ~meth ~target = lookup_deep deep ~meth ~target))
          [ Method.get; Method.post; Method.head ])
      paths
  in
  check
    [
      definition "/:x/end" Method.post 0;
      definition "/a/:x" Method.get 1;
      definition "/a/end" Method.post 2;
      definition "/*all" Method.get 3;
      definition "/a/end" Method.post 4;
      definition "/" Method.get 5;
      definition "//a" Method.head 6;
    ]
    [
      "/a/end";
      "/";
      "//a";
      "/a/";
      "/a/%2F?x=1";
      "*";
      "/" ^ String.make 8192 'x';
      "/" ^ String.concat "/" (List.init 65 (fun _ -> "x"));
    ];
  let rng = Random.State.make [| 7331 |] in
  for _ = 1 to 100 do
    let definitions =
      List.init 30 (fun id ->
          let base =
            if Random.State.int rng 5 = 0 then "/:prefix"
            else "/r" ^ string_of_int (Random.State.int rng 10)
          in
          let suffix =
            List.nth [ "/:id"; "/tail"; "/*rest" ] (Random.State.int rng 3)
          in
          definition (base ^ suffix)
            (if Random.State.bool rng then Method.get else Method.post)
            id)
    in
    let paths =
      List.init 40 (fun _ ->
          "/r"
          ^ string_of_int (Random.State.int rng 12)
          ^ List.nth
              [ "/tail"; "/value"; "/a/b"; "/"; "/%2F?q=x" ]
              (Random.State.int rng 5))
    in
    check definitions paths
  done

let jobs ?(preflight = true) () =
  (* Runs before the timer, on every sample and catalog request. *)
  if preflight then check_equivalence ();
  List.concat_map
    (fun shape ->
      List.concat_map
        (fun count ->
          let definitions =
            List.init count (fun id ->
                let pattern =
                  match shape with
                  | "distinct" -> "/r" ^ string_of_int id ^ "/:id"
                  | "shared" -> "/api/r" ^ string_of_int id ^ "/:id"
                  | "application" ->
                      if id mod 10 = 0 then "/api/:resource/special"
                      else "/api/v1/r" ^ string_of_int id ^ "/:id"
                  | _ ->
                      if id mod 10 = 0 then "/:prefix/special"
                      else "/r" ^ string_of_int id ^ "/:id"
                in
                definition pattern
                  (if shape = "application" && id mod 7 = 0 then Method.post
                   else Method.get)
                  id)
          in
          let linear = reference definitions
          and indexed = compile definitions
          and deep = compile_deep definitions in
          let base =
            if shape = "shared" then "/api/r"
            else if shape = "application" then "/api/v1/r"
            else "/r"
          in
          let path id = base ^ string_of_int id ^ "/value" in
          let probes =
            [
              ("early", path 1);
              ("middle", path ((count / 2) + 1));
              ("last", path (count - 1));
              ("missing", base ^ "missing/value");
              ("method", path (count - 1));
            ]
          in
          let make workload iterations implementation work =
            job ~comparison:workload ~implementation "router-experiment"
              ("external/" ^ workload ^ "/" ^ implementation)
              iterations work
          in
          let construction = Printf.sprintf "%s/compile/%d" shape count in
          let builds =
            [
              make construction 10 "httpkit" (fun () ->
                  ignore (reference definitions));
              make construction 10 "prefix-index" (fun () ->
                  let next = compile definitions in
                  require (next.slots = indexed.slots));
              make construction 10 "deep-index" (fun () ->
                  let next = compile_deep definitions in
                  require (next.slots = count && next.nodes = deep.nodes));
            ]
          in
          let targets =
            Array.init 100 (fun i ->
                ok
                  (Target.of_string
                     (path (if i mod 10 <> 0 then 1 else i * 13 mod count))))
          in
          let expected =
            Array.map
              (fun target -> R.lookup linear ~meth:Method.get ~target)
              targets
          in
          let hot implementation lookup =
            make (Printf.sprintf "%s/hot-skew/%d" shape count) 50 implementation
              (fun () ->
                Array.iteri
                  (fun i target ->
                    require (lookup ~meth:Method.get ~target = expected.(i)))
                  targets)
          in
          builds
          @ [
              hot "httpkit" (R.lookup linear);
              hot "prefix-index" (lookup indexed);
              hot "deep-index" (lookup_deep deep);
            ]
          @ List.concat_map
              (fun (label, path) ->
                let target = ok (Target.of_string path) in
                let meth =
                  if label = "method" then Method.post else Method.get
                in
                let expected = R.lookup linear ~meth ~target in
                require (expected = lookup indexed ~meth ~target);
                require (expected = lookup_deep deep ~meth ~target);
                let workload =
                  Printf.sprintf "%s/lookup/%d/%s" shape count label
                in
                [
                  make workload 5000 "httpkit" (fun () ->
                      require (R.lookup linear ~meth ~target = expected));
                  make workload 5000 "prefix-index" (fun () ->
                      require (lookup indexed ~meth ~target = expected));
                  make workload 5000 "deep-index" (fun () ->
                      require (lookup_deep deep ~meth ~target = expected));
                ])
              probes)
        [ 10; 100; 1000 ])
    [ "distinct"; "shared"; "fallback-heavy"; "application" ]
