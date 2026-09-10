open Contract

type conn = {
  mutable stage : int;
  mutable message : int;
  mutable length : int;
  mutable received : int;
  incoming : char Queue.t;
  outgoing : char Queue.t;
  mutable waiters : int;
  mutable deadline : int64 option;
  accepted : (int, unit) Hashtbl.t;
  ghost : (int, unit) Hashtbl.t;
}

let make fault =
  let module S = struct
    type t = {
      config : Scenario.config;
      mutable now : int64;
      conns : (int, conn) Hashtbl.t;
    }

    let create config = { config; now = 0L; conns = Hashtbl.create 8 }

    let sorted t =
      Hashtbl.to_seq t.conns |> List.of_seq
      |> List.sort (fun (a, _) (b, _) -> compare a b)

    let wake c =
      let n = c.waiters in
      c.waiters <- 0;
      if n = 0 then [] else [ Woken n ]

    let close reason c =
      if c.stage = 3 then []
      else
        let ev = if fault = Miss_wakeup then [] else wake c in
        c.stage <- 3;
        Queue.clear c.incoming;
        Queue.clear c.outgoing;
        c.deadline <- None;
        ev
        @
        match reason with
        | None -> [ Closed ]
        | Some s -> [ Failed s; Closed ]

    let take q n = String.init n (fun _ -> Queue.take q)

    let put q s n =
      for i = 0 to n - 1 do
        Queue.add s.[i] q
      done

    let step t action =
      let open Scenario in
      match action with
      | Open id ->
          Hashtbl.add t.conns id
            {
              stage = 0;
              message = 0;
              length = 0;
              received = 0;
              incoming = Queue.create ();
              outgoing = Queue.create ();
              waiters = 0;
              deadline = Some (Int64.add t.now t.config.header_deadline_ns);
              accepted = Hashtbl.create 8;
              ghost = Hashtbl.create 8;
            };
          []
      | Advance ns ->
          t.now <- Int64.add t.now ns;
          List.concat_map
            (fun (id, c) ->
              match c.deadline with
              | Some d when d <= t.now ->
                  List.map (fun e -> (id, e)) (close (Some "header-timeout") c)
              | _ -> [])
            (sorted t)
      | _ ->
          let id = Option.get (connection action) in
          let c = Hashtbl.find t.conns id in
          let events =
            match action with
            | Cancel _ -> close (Some "cancelled") c
            | Read_error _ -> close (Some "read-error") c
            | Write_error _ -> close (Some "write-error") c
            | Shutdown _ ->
                if Queue.is_empty c.incoming && Queue.is_empty c.outgoing then
                  close None c
                else [ Backpressured ]
            | _ when c.stage = 3 -> [ Rejected "closed" ]
            | Begin (_, m, n) ->
                if
                  c.stage = 0
                  || c.stage = 2 && Queue.is_empty c.incoming
                     && Queue.is_empty c.outgoing
                  || fault = Reuse_unread
                then (
                  c.stage <- 1;
                  c.message <- m;
                  c.length <- n;
                  c.received <- 0;
                  c.deadline <- None;
                  Queue.clear c.incoming;
                  [ Headers m ])
                else [ Rejected "unread-or-active" ]
            | Input (_, s) ->
                if s = "" && fault = Empty_eof then close (Some "truncated") c
                else if c.stage = 2 && fault = Body_after_end then
                  [ Data (c.message, s) ]
                else if c.stage > 1 then [ Rejected "not-reading" ]
                else (
                  if fault = Sliding_deadline && c.stage = 0 then
                    c.deadline <-
                      Some (Int64.add t.now t.config.header_deadline_ns);
                  let cap =
                    if fault = Overbuffer then String.length s
                    else
                      max 0 (t.config.incoming_limit - Queue.length c.incoming)
                  in
                  let n =
                    min cap
                      (if c.stage = 0 then String.length s
                       else min (String.length s) (c.length - c.received))
                  in
                  put c.incoming s n;
                  if c.stage = 1 then c.received <- c.received + n;
                  let ev = if c.stage = 1 && n > 0 then wake c else [] in
                  Accepted_input
                    (if fault = Overconsume then String.length s + 1 else n)
                  :: ev)
            | Consume (_, n) ->
                if n > Queue.length c.incoming then [ Rejected "consume-range" ]
                else if c.stage <> 1 then [ Rejected "not-body" ]
                else [ Data (c.message, take c.incoming n) ]
            | Send (_, token, s) ->
                if Hashtbl.mem c.accepted token then
                  [ Rejected "duplicate-token" ]
                else if
                  String.length s
                  > t.config.outgoing_limit - Queue.length c.outgoing
                then (
                  if fault = Double_accept then Hashtbl.replace c.ghost token ();
                  [ Backpressured ])
                else (
                  put c.outgoing s (String.length s);
                  if Hashtbl.mem c.ghost token then (
                    put c.outgoing s (String.length s);
                    Hashtbl.remove c.ghost token);
                  Hashtbl.add c.accepted token ();
                  [ Accepted ])
            | Write (_, allow) ->
                let n = min allow (Queue.length c.outgoing) in
                if n = 0 then [ Blocked ]
                else
                  let s = take c.outgoing n in
                  [
                    Written
                      (if fault = Drop_write then String.sub s 0 (n - 1)
                       else if fault = Duplicate_write then s ^ String.sub s 0 1
                       else s);
                  ]
            | Finish _ ->
                if
                  c.stage = 1 && c.received = c.length
                  && Queue.is_empty c.incoming && Queue.is_empty c.outgoing
                then (
                  c.stage <- 2;
                  let ev = wake c in
                  ev
                  @
                  if fault = Double_complete then
                    [ Complete c.message; Complete c.message ]
                  else [ Complete c.message ])
                else [ Rejected "unfinished" ]
            | Wait_body _ ->
                if c.stage <> 1 then [ Rejected "not-body" ]
                else if
                  (not (Queue.is_empty c.incoming)) || c.received = c.length
                then [ Woken 1 ]
                else (
                  c.waiters <- c.waiters + 1;
                  [ Blocked ])
            | Eof _ ->
                if (c.stage = 1 && c.received = c.length) || c.stage = 2 then []
                else close (Some "truncated") c
            | Run (_, budget) ->
                if fault = Spin then List.init budget (fun _ -> Accepted)
                else [ Blocked ]
            | Open _ | Advance _ -> assert false
          in
          List.map (fun e -> (id, e)) events

    let snapshots t =
      List.map
        (fun (id, c) ->
          {
            connection = id;
            phase =
              (match c.stage with
              | 0 -> "headers"
              | 1 -> "body:" ^ string_of_int c.message
              | 2 -> "done:" ^ string_of_int c.message
              | _ -> "closed");
            incoming = Queue.length c.incoming;
            outgoing = Queue.length c.outgoing;
            waiters = c.waiters;
            timers = (if c.deadline = None then 0 else 1);
            deadline = c.deadline;
            closed = c.stage = 3;
          })
        (sorted t)
  end in
  (module S : SUBJECT)
