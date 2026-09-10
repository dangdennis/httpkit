type phase = Idle | Head | Body | Write | Shutdown

type policy = {
  header : float;
  body_idle : float option;
  write_idle : float option;
  keep_alive : float;
  graceful : float;
}

let policy ?(header = 10.) ?(body_idle = Some 30.) ?(write_idle = Some 30.)
    ?(keep_alive = 30.) ?(graceful = 10.) () =
  let valid n = Float.is_finite n && n > 0. in
  if
    (not (List.for_all valid [ header; keep_alive; graceful ]))
    || (not (Option.fold ~none:true ~some:valid body_idle))
    || not (Option.fold ~none:true ~some:valid write_idle)
  then Error "durations must be positive and finite"
  else Ok { header; body_idle; write_idle; keep_alive; graceful }

let default = Result.get_ok (policy ())

let duration p = function
  | Head -> Some p.header
  | Body -> p.body_idle
  | Write -> p.write_idle
  | Idle -> Some p.keep_alive
  | Shutdown -> Some p.graceful

type t = { phase : phase option; deadline : float option }

let empty = { phase = None; deadline = None }

let observe policy ~now ~phase t =
  if phase = t.phase then t
  else
    {
      phase;
      deadline =
        Option.bind phase (fun p -> Option.map (( +. ) now) (duration policy p));
    }

let progress policy ~now t =
  match t.phase with
  | Some ((Idle | Body | Write) as phase) ->
      { t with deadline = Option.map (( +. ) now) (duration policy phase) }
  | _ -> t

let remaining ~now t = Option.map (fun deadline -> deadline -. now) t.deadline
