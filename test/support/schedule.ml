let partitions s =
  if String.length s > 12 then
    invalid_arg "exhaustive partitions limited to 12 bytes";
  let rec go off =
    if off = String.length s then [ [] ]
    else
      List.concat
        (List.init
           (String.length s - off)
           (fun i ->
             List.map
               (fun suffix -> String.sub s off (i + 1) :: suffix)
               (go (off + i + 1))))
  in
  go 0

let single_splits s =
  if String.length s > 4096 then invalid_arg "single splits limited to 4 KiB";
  List.init
    (String.length s + 1)
    (fun i -> [ String.sub s 0 i; String.sub s i (String.length s - i) ])

type node = { id : int; after : int list; action : Scenario.action }

let topological ?(limit = 10000) nodes =
  if List.length nodes > 8 || limit <= 0 then
    Error "schedule size/limit out of range"
  else
    let ids = List.map (fun n -> n.id) nodes in
    if
      List.length (List.sort_uniq compare ids) <> List.length ids
      || List.exists
           (fun n -> List.exists (fun id -> not (List.mem id ids)) n.after)
           nodes
    then Error "invalid dependency IDs"
    else
      let out = ref [] and count = ref 0 and truncated = ref false in
      let rec visit done_ids actions remaining =
        if !count > limit then ()
        else
          match remaining with
          | [] ->
              incr count;
              if !count <= limit then out := List.rev actions :: !out
              else truncated := true
          | _ ->
              List.iter
                (fun n ->
                  if List.for_all (fun id -> List.mem id done_ids) n.after then
                    visit (n.id :: done_ids) (n.action :: actions)
                      (List.filter (fun m -> m.id <> n.id) remaining))
                remaining
      in
      visit [] [] nodes;
      if !count = 0 then Error "cyclic dependency graph"
      else Ok (List.rev !out, !truncated)
