type event =
  | Accepted_input of int
  | Headers of int
  | Data of int * string
  | Complete of int
  | Written of string
  | Accepted
  | Backpressured
  | Rejected of string
  | Closed
  | Woken of int
  | Failed of string
  | Blocked

type observation = int * event

type snapshot = {
  connection : int;
  phase : string;
  incoming : int;
  outgoing : int;
  waiters : int;
  timers : int;
  deadline : int64 option;
  closed : bool;
}

type fault =
  | Correct
  | Drop_write
  | Duplicate_write
  | Overconsume
  | Empty_eof
  | Double_accept
  | Double_complete
  | Body_after_end
  | Reuse_unread
  | Overbuffer
  | Miss_wakeup
  | Sliding_deadline
  | Spin

let faults =
  [
    Drop_write;
    Duplicate_write;
    Overconsume;
    Empty_eof;
    Double_accept;
    Double_complete;
    Body_after_end;
    Reuse_unread;
    Overbuffer;
    Miss_wakeup;
    Sliding_deadline;
    Spin;
  ]

let fault_name = function
  | Correct -> "correct"
  | Drop_write -> "drop-write"
  | Duplicate_write -> "duplicate-write"
  | Overconsume -> "overconsume"
  | Empty_eof -> "empty-eof"
  | Double_accept -> "double-accept"
  | Double_complete -> "double-complete"
  | Body_after_end -> "body-after-end"
  | Reuse_unread -> "reuse-unread"
  | Overbuffer -> "overbuffer"
  | Miss_wakeup -> "miss-wakeup"
  | Sliding_deadline -> "sliding-deadline"
  | Spin -> "spin"

let fault_of_string s =
  match List.find_opt (fun f -> fault_name f = s) (Correct :: faults) with
  | Some f -> Ok f
  | None -> Error "unknown synthetic subject"

let num n = `String (string_of_int n)

let event_json = function
  | Accepted_input n -> `List [ `String "input"; num n ]
  | Headers m -> `List [ `String "headers"; num m ]
  | Data (m, s) ->
      `List [ `String "data"; num m; `String (Base64.encode_exn s) ]
  | Complete m -> `List [ `String "complete"; num m ]
  | Written s -> `List [ `String "written"; `String (Base64.encode_exn s) ]
  | Accepted -> `String "accepted"
  | Backpressured -> `String "backpressured"
  | Rejected s -> `List [ `String "rejected"; `String s ]
  | Closed -> `String "closed"
  | Woken n -> `List [ `String "woken"; num n ]
  | Failed s -> `List [ `String "failed"; `String s ]
  | Blocked -> `String "blocked"

let observations_to_json obs =
  `List
    (List.map
       (fun (c, e) -> `Assoc [ ("connection", num c); ("event", event_json e) ])
       obs)

let snapshots_to_json ss =
  `List
    (List.map
       (fun s ->
         `Assoc
           [
             ("connection", num s.connection);
             ("phase", `String s.phase);
             ("incoming", num s.incoming);
             ("outgoing", num s.outgoing);
             ("waiters", num s.waiters);
             ("timers", num s.timers);
             ( "deadline",
               match s.deadline with
               | None -> `Null
               | Some n -> `String (Int64.to_string n) );
             ("closed", `Bool s.closed);
           ])
       ss)

let normalize obs =
  let rec loop acc = function
    | [] -> List.rev acc
    | (c, Data (m, s)) :: rest -> (
        match acc with
        | (c', Data (m', s')) :: tail when c = c' && m = m' ->
            loop ((c, Data (m, s' ^ s)) :: tail) rest
        | _ -> loop ((c, Data (m, s)) :: acc) rest)
    | x :: rest -> loop (x :: acc) rest
  in
  loop [] obs

module type SUBJECT = sig
  type t

  val create : Scenario.config -> t
  val step : t -> Scenario.action -> observation list
  val snapshots : t -> snapshot list
end
