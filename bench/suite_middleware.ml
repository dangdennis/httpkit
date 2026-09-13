open Httpkit_core
open Suite_support
module M = Httpkit_middleware

let jobs () =
  let request =
    Request.create ~meth:Method.get
      ~target:(ok (Target.of_string "/"))
      ~headers:Headers.empty ()
  in
  List.concat_map
    (fun depth ->
      (* Build handlers once, as an application would at startup. Each layer does
       the same integer increment; these are plumbing costs, not auth costs. *)
      let basic =
        M.Basic.chain
          (List.init depth (fun _ next request -> 1 + next request))
          (fun _ -> 0)
      in
      let context =
        M.Context.chain
          (List.init depth (fun _ next n request -> next (n + 1) request))
          (fun n _ -> n)
      in
      let transition =
        List.fold_left M.Transition.compose M.Transition.identity
          (List.init depth (fun _ -> M.Transition.map_context (( + ) 1)))
          (fun n _ -> n)
      in
      List.map
        (fun (style, run) ->
          job "middleware" (Printf.sprintf "%s/depth-%d" style depth) 10000
            (fun () -> require (run () = depth)))
        [
          ("basic", fun () -> basic request);
          ("context", fun () -> context 0 request);
          ("transition", fun () -> transition 0 request);
        ])
    [ 0; 1; 5; 20 ]
  @ List.map
      (fun accept ->
        let handler =
          M.Transition.guard
            (fun n _ -> if accept then Ok (n + 1) else Error (-1))
            ~reject:Fun.id
            (fun n _ -> n)
        in
        job "middleware"
          (if accept then "guard/accept" else "guard/reject")
          10000
          (fun () -> require (handler 0 request = if accept then 1 else -1)))
      [ true; false ]
