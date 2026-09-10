type result = { scenario : Scenario.t; attempts : int; exhausted : bool }

let minimize ?(max_attempts = 1000) ?(expired = fun () -> false) fault original
    =
  let baseline = Runner.run fault original in
  if baseline.failure = None then invalid_arg "cannot shrink a passing scenario";
  let attempts = ref 0 and exhausted = ref false in
  let accept s =
    if !attempts >= max_attempts || expired () then (
      exhausted := true;
      false)
    else (
      incr attempts;
      match Scenario.validate s with
      | Error _ -> false
      | Ok () -> Runner.same_failure baseline (Runner.run fault s))
  in
  let rec remove s chunk =
    if !exhausted || chunk = 0 then s
    else
      let n = List.length s.Scenario.actions in
      let rec positions i =
        if i >= n then remove s (chunk / 2)
        else
          let actions =
            List.filteri (fun j _ -> j < i || j >= i + chunk) s.actions
          in
          let candidate = { s with actions } in
          if accept candidate then
            remove candidate (min chunk (List.length actions))
          else if !exhausted then s
          else positions (i + chunk)
      in
      positions 0
  in
  let s = remove original (max 1 (List.length original.actions / 2)) in
  let rec simplify s index =
    if !exhausted || index >= List.length s.Scenario.actions then s
    else
      let a = List.nth s.actions index in
      let variants =
        let open Scenario in
        match a with
        | Input (c, d) when d <> "" ->
            [ Input (c, ""); Input (c, String.sub d 0 (String.length d / 2)) ]
        | Send (c, t, d) when d <> "" ->
            [
              Send (c, t, ""); Send (c, t, String.sub d 0 (String.length d / 2));
            ]
        | Advance n when n > 0L -> [ Advance 0L; Advance (Int64.div n 2L) ]
        | Consume (c, n) when n > 0 -> [ Consume (c, 0); Consume (c, n / 2) ]
        | Write (c, n) when n > 1 -> [ Write (c, 1); Write (c, n / 2) ]
        | Run (c, n) when n > 1 -> [ Run (c, 1) ]
        | _ -> []
      in
      let rec choose = function
        | [] -> simplify s (index + 1)
        | replacement :: rest ->
            let candidate =
              {
                s with
                actions =
                  List.mapi
                    (fun i a -> if i = index then replacement else a)
                    s.actions;
              }
            in
            if accept candidate then simplify candidate index
            else if !exhausted then s
            else choose rest
      in
      choose variants
  in
  let s = simplify s 0 in
  { scenario = s; attempts = !attempts; exhausted = !exhausted }
