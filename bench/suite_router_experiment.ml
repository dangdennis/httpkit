open Http_kit_core
open Suite_support
module R = Http_kit_router
module Prefixes = Map.Make (String)

type definition = { prefix : string option; route : int R.route }
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
  { prefix; route = R.route ~meth (ok (R.pattern pattern)) value }

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

let check_equivalence () =
  let check definitions paths =
    let linear = reference definitions and indexed = compile definitions in
    List.iter
      (fun path ->
        let target = ok (Target.of_string ~max_length:16384 path) in
        List.iter
          (fun meth ->
            require
              (R.lookup linear ~meth ~target = lookup indexed ~meth ~target))
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

let jobs () =
  (* Runs before the timer, on every sample and catalog request. *)
  check_equivalence ();
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
                  | _ ->
                      if id mod 10 = 0 then "/:prefix/special"
                      else "/r" ^ string_of_int id ^ "/:id"
                in
                definition pattern Method.get id)
          in
          let linear = reference definitions
          and indexed = compile definitions in
          let base = if shape = "shared" then "/api/r" else "/r" in
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
              make construction 10 "http-kit" (fun () ->
                  ignore (reference definitions));
              make construction 10 "prefix-index" (fun () ->
                  let next = compile definitions in
                  require (next.slots = indexed.slots));
            ]
          in
          builds
          @ List.concat_map
              (fun (label, path) ->
                let target = ok (Target.of_string path) in
                let meth =
                  if label = "method" then Method.post else Method.get
                in
                let expected = R.lookup linear ~meth ~target in
                require (expected = lookup indexed ~meth ~target);
                let workload =
                  Printf.sprintf "%s/lookup/%d/%s" shape count label
                in
                [
                  make workload 5000 "http-kit" (fun () ->
                      require (R.lookup linear ~meth ~target = expected));
                  make workload 5000 "prefix-index" (fun () ->
                      require (lookup indexed ~meth ~target = expected));
                ])
              probes)
        [ 10; 100; 1000 ])
    [ "distinct"; "shared"; "fallback-heavy" ]
