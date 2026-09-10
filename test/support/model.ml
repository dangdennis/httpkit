open Contract

type phase = Header | Body of int * int * int | Done of int | Shut

type conn = {
  phase : phase;
  input : string;
  output : string;
  waiters : int;
  deadline : int64 option;
  tokens : int list;
}

type t = { config : Scenario.config; now : int64; conns : (int * conn) list }

let create config = { config; now = 0L; conns = [] }

let new_conn deadline =
  {
    phase = Header;
    input = "";
    output = "";
    waiters = 0;
    deadline = Some deadline;
    tokens = [];
  }

let wake c =
  ({ c with waiters = 0 }, if c.waiters = 0 then [] else [ Woken c.waiters ])

let close reason c =
  if c.phase = Shut then (c, [])
  else
    let c, events = wake c in
    ( { c with phase = Shut; input = ""; output = ""; deadline = None },
      events
      @ match reason with None -> [ Closed ] | Some s -> [ Failed s; Closed ] )

let update t id f =
  let c = List.assoc id t.conns in
  let c, obs = f c in
  ( {
      t with
      conns = List.map (fun (i, old) -> (i, if i = id then c else old)) t.conns;
    },
    List.map (fun e -> (id, e)) obs )

let step t action =
  let open Scenario in
  match action with
  | Open id ->
      ( {
          t with
          conns =
            t.conns
            @ [ (id, new_conn (Int64.add t.now t.config.header_deadline_ns)) ];
        },
        [] )
  | Advance ns ->
      let t = { t with now = Int64.add t.now ns } in
      List.fold_left
        (fun (t, obs) (id, _) ->
          let t, out =
            update t id (fun c ->
                match c.deadline with
                | Some d when d <= t.now -> close (Some "header-timeout") c
                | _ -> (c, []))
          in
          (t, obs @ out))
        (t, [])
        (List.sort compare t.conns)
  | _ ->
      let id = Option.get (connection action) in
      update t id (fun c ->
          match action with
          | Cancel _ -> close (Some "cancelled") c
          | Read_error _ -> close (Some "read-error") c
          | Write_error _ -> close (Some "write-error") c
          | Shutdown _ ->
              if c.output = "" && c.input = "" then close None c
              else (c, [ Backpressured ])
          | _ when c.phase = Shut -> (c, [ Rejected "closed" ])
          | Begin (_, m, n) -> (
              match c.phase with
              | (Header | Done _) when c.input = "" && c.output = "" ->
                  ( { c with phase = Body (m, n, 0); deadline = None },
                    [ Headers m ] )
              | Header ->
                  ( {
                      c with
                      phase = Body (m, n, 0);
                      input = "";
                      deadline = None;
                    },
                    [ Headers m ] )
              | _ -> (c, [ Rejected "unread-or-active" ]))
          | Input (_, s) -> (
              let available =
                max 0 (t.config.incoming_limit - String.length c.input)
              in
              match c.phase with
              | Header ->
                  let n = min available (String.length s) in
                  ( { c with input = c.input ^ String.sub s 0 n },
                    [ Accepted_input n ] )
              | Body (m, length, received) ->
                  let n =
                    min available (min (String.length s) (length - received))
                  in
                  let c =
                    {
                      c with
                      input = c.input ^ String.sub s 0 n;
                      phase = Body (m, length, received + n);
                    }
                  in
                  let c, ev = if n > 0 then wake c else (c, []) in
                  (c, Accepted_input n :: ev)
              | _ -> (c, [ Rejected "not-reading" ]))
          | Consume (_, n) -> (
              if n > String.length c.input then (c, [ Rejected "consume-range" ])
              else
                match c.phase with
                | Body (m, _, _) ->
                    ( {
                        c with
                        input = String.sub c.input n (String.length c.input - n);
                      },
                      [ Data (m, String.sub c.input 0 n) ] )
                | _ -> (c, [ Rejected "not-body" ]))
          | Send (_, token, s) ->
              if List.mem token c.tokens then (c, [ Rejected "duplicate-token" ])
              else if
                String.length s
                > t.config.outgoing_limit - String.length c.output
              then (c, [ Backpressured ])
              else
                ( { c with output = c.output ^ s; tokens = token :: c.tokens },
                  [ Accepted ] )
          | Write (_, allow) ->
              let n = min allow (String.length c.output) in
              if n = 0 then (c, [ Blocked ])
              else
                ( {
                    c with
                    output = String.sub c.output n (String.length c.output - n);
                  },
                  [ Written (String.sub c.output 0 n) ] )
          | Finish _ -> (
              match c.phase with
              | Body (m, length, received)
                when length = received && c.input = "" && c.output = "" ->
                  let c, ev = wake c in
                  ({ c with phase = Done m }, ev @ [ Complete m ])
              | _ -> (c, [ Rejected "unfinished" ]))
          | Wait_body _ -> (
              match c.phase with
              | Body (_, n, r) when c.input <> "" || n = r -> (c, [ Woken 1 ])
              | Body _ -> ({ c with waiters = c.waiters + 1 }, [ Blocked ])
              | _ -> (c, [ Rejected "not-body" ]))
          | Eof _ -> (
              match c.phase with
              | Body (_, n, r) when n = r -> (c, [])
              | Done _ -> (c, [])
              | _ -> close (Some "truncated") c)
          | Run _ -> (c, [ Blocked ])
          | Open _ | Advance _ -> assert false)

let snapshots t =
  List.map
    (fun (id, c) ->
      {
        connection = id;
        phase =
          (match c.phase with
          | Header -> "headers"
          | Body (m, _, _) -> "body:" ^ string_of_int m
          | Done m -> "done:" ^ string_of_int m
          | Shut -> "closed");
        incoming = String.length c.input;
        outgoing = String.length c.output;
        waiters = c.waiters;
        timers = (if c.deadline = None then 0 else 1);
        deadline = c.deadline;
        closed = c.phase = Shut;
      })
    (List.sort compare t.conns)
