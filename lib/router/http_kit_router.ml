open Http_kit_core

type error =
  | Invalid_pattern
  | Invalid_limit
  | Too_many_routes
  | Target_limit
  | Segment_limit
  | Unsupported_target

let error_to_string = function
  | Invalid_pattern -> "invalid route pattern"
  | Invalid_limit -> "invalid routing limit"
  | Too_many_routes -> "route count limit"
  | Target_limit -> "routing target byte limit"
  | Segment_limit -> "routing path segment limit"
  | Unsupported_target -> "routing requires an origin-form target"

type segment = Literal of string | Parameter of string | Wildcard of string
type pattern = segment list

module Params = struct
  type t = (string * string) list

  let find = List.assoc_opt
  let to_list t = t
end

module Names = Set.Make (String)

let segments path =
  if path = "/" then []
  else String.split_on_char '/' (String.sub path 1 (String.length path - 1))

let identifier name =
  let first = function 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false in
  String.length name > 0
  && first name.[0]
  && String.for_all (fun c -> first c || (c >= '0' && c <= '9')) name

let pattern ?(max_bytes = 4096) ?(max_segments = 64) text =
  if max_bytes <= 0 || max_segments <= 0 then Error Invalid_limit
  else if
    String.length text = 0
    || String.length text > max_bytes
    || text.[0] <> '/'
    || String.contains text '?'
  then Error Invalid_pattern
  else
    match Target.of_string ~max_length:max_bytes text with
    | Error _ -> Error Invalid_pattern
    | Ok _ ->
        let parts = segments text in
        if List.length parts > max_segments then Error Segment_limit
        else
          let rec parse names acc = function
            | [] -> Ok (List.rev acc)
            | part :: rest ->
                if String.length part > 0 && (part.[0] = ':' || part.[0] = '*')
                then
                  let name = String.sub part 1 (String.length part - 1) in
                  if
                    (not (identifier name))
                    || Names.mem name names
                    || (part.[0] = '*' && rest <> [])
                  then Error Invalid_pattern
                  else
                    let segment =
                      if part.[0] = ':' then Parameter name else Wildcard name
                    in
                    parse (Names.add name names) (segment :: acc) rest
                else parse names (Literal part :: acc) rest
          in
          parse Names.empty [] parts

type 'a route = { meth : Method.t; pattern : pattern; value : 'a }

let route ~meth pattern value = { meth; pattern; value }

type 'a t = {
  routes : 'a route array;
  max_target_bytes : int;
  max_segments : int;
}

let compile ?(max_routes = 1024) ?(max_target_bytes = 8192) ?(max_segments = 64)
    routes =
  if max_routes < 0 || max_target_bytes < 0 || max_segments < 0 then
    Error Invalid_limit
  else
    let rec bounded remaining = function
      | [] -> true
      | _ :: _ when remaining = 0 -> false
      | _ :: rest -> bounded (remaining - 1) rest
    in
    if not (bounded max_routes routes) then Error Too_many_routes
    else Ok { routes = Array.of_list routes; max_target_bytes; max_segments }

type 'a matched = { value : 'a; params : Params.t }

type 'a outcome =
  | Matched of 'a matched
  | Not_found
  | Method_not_allowed of Method.t list

(* Keep recursion at module scope: a table miss must not allocate a pair of
   helper closures for every route that it scans. Capture/result allocation
   remains explicit in the successful branches below. *)
let rec matches ~capture acc pattern parts =
  match (pattern, parts) with
  | [], [] -> Some (List.rev acc)
  | [ Wildcard name ], parts ->
      (* Materialize wildcard bytes only for the selected method. *)
      let acc =
        if capture then (name, String.concat "/" parts) :: acc else acc
      in
      Some (List.rev acc)
  | Literal expected :: rest, actual :: tail when expected = actual ->
      matches ~capture acc rest tail
  | Parameter name :: rest, actual :: tail when actual <> "" ->
      let acc = if capture then (name, actual) :: acc else acc in
      matches ~capture acc rest tail
  | _ -> None

let lookup table ~meth ~target =
  let text = Target.to_string target in
  if String.length text > table.max_target_bytes then Error Target_limit
  else if String.length text = 0 || text.[0] <> '/' then
    Error Unsupported_target
  else
    let path =
      match String.index_opt text '?' with
      | None -> text
      | Some n -> String.sub text 0 n
    in
    let parts = segments path in
    if List.length parts > table.max_segments then Error Segment_limit
    else
      let rec search index seen allowed =
        if index = Array.length table.routes then
          Ok
            (if allowed = [] then Not_found
             else Method_not_allowed (List.rev allowed))
        else
          let route = table.routes.(index) in
          let same_method = Method.equal meth route.meth in
          match matches ~capture:same_method [] route.pattern parts with
          | Some params when same_method ->
              Ok (Matched { value = route.value; params })
          | Some _ ->
              let name = Method.to_string route.meth in
              if Names.mem name seen then search (index + 1) seen allowed
              else
                search (index + 1) (Names.add name seen) (route.meth :: allowed)
          | None -> search (index + 1) seen allowed
      in
      search 0 Names.empty []
