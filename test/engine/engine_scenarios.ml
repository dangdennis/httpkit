open Httpkit_core
module E = Httpkit_engine

let require b message = if not b then failwith message
let ok = function Ok x -> x | Error e -> failwith (E.error_to_string e)
let value = Result.get_ok
let payload = String.init 64 (fun i -> Char.chr (65 + (i mod 26)))
let expected = "HTTP/1.1 200 \r\ncontent-length: 64\r\n\r\n" ^ payload

(* This model knows only the golden output and accepted application commands.
   It never asks the codec to serialize the expected bytes. *)
type model = {
  sent : int;
  acked : int;
  finished : bool;
  terminal : bool;
  closed_events : int;
}

let run bytes =
  let t = ok (E.server ~output_limit:80 ()) in
  let request = "GET / HTTP/1.1\r\nHost: x\r\n\r\n" in
  ignore (ok (E.offer t request ~off:0 ~len:(String.length request)));
  let id =
    match E.poll_event t with
    | Some (E.Request (id, _)) -> id
    | _ -> failwith "missing request"
  in
  require (E.poll_event t = Some (E.Complete id)) "missing input completion";
  let response =
    Response.create ~status:Status.ok
      ~headers:(value (Headers.of_list [ ("content-length", "64") ]))
      ()
  in
  require (ok (E.respond t id response) = E.Accepted ()) "response rejected";
  let model =
    ref
      {
        sent = 0;
        acked = 0;
        finished = false;
        terminal = false;
        closed_events = 0;
      }
  in
  let ack count =
    match E.output t with
    | None -> ()
    | Some (s, off, len) ->
        let n = min count len in
        require (!model.acked + n <= String.length expected) "extra output";
        require
          (String.sub s off n = String.sub expected !model.acked n)
          "wrong acknowledged prefix";
        ignore (ok (E.acknowledge t n));
        model := { !model with acked = !model.acked + n }
  in
  let send () =
    if (not !model.terminal) && (not !model.finished) && !model.sent < 64 then
      let n = min 8 (64 - !model.sent) in
      let before = E.queued_output_bytes t in
      match E.send_data t id (String.sub payload !model.sent n) with
      | Ok (E.Accepted ()) -> model := { !model with sent = !model.sent + n }
      | Ok E.Backpressured ->
          require
            (E.queued_output_bytes t = before)
            "rejected command mutated output"
      | Error _ -> failwith "valid write rejected"
  in
  let finish () =
    if (not !model.terminal) && not !model.finished then
      match E.finish t id with
      | Ok (E.Accepted ()) ->
          require (!model.sent = 64) "short body completed";
          model := { !model with finished = true }
      | Ok E.Backpressured -> ()
      | Error (E.Protocol Httpkit_http1.Invalid_length) ->
          require (!model.sent < 64) "complete body rejected";
          model := { !model with terminal = true }
      | Error _ -> failwith "unexpected finish error"
  in
  String.iter
    (fun c ->
      (match Char.code c mod 8 with
      | 0 -> send ()
      | 1 -> ack (1 + (Char.code c mod 11))
      | 2 -> require (E.output t = E.output t) "unstable pending output"
      | 3 ->
          let before = E.queued_output_bytes t in
          ignore (E.acknowledge t max_int);
          require (E.queued_output_bytes t = before) "bad ack mutated output"
      | 4 -> finish ()
      | 5 ->
          if (not !model.finished) && not !model.terminal then
            require
              (ok (E.offer t request ~off:0 ~len:(String.length request)) = 0)
              "premature pipeline admission"
      | 6 -> (
          match E.poll_event t with
          | None -> ()
          | Some (E.Closed _) ->
              require !model.terminal "unexpected close";
              model := { !model with closed_events = !model.closed_events + 1 }
          | _ -> failwith "unexpected lifecycle event")
      | _ ->
          E.abort t E.Cancelled;
          model := { !model with terminal = true });
      require
        (E.queued_output_bytes t <= 80 && E.queued_input_bytes t = 0)
        "retention bound";
      require (!model.closed_events <= 1) "duplicate terminal event";
      if !model.terminal then
        require (E.output t = None) "output survived cancellation")
    bytes;
  if not !model.terminal then (
    for _ = 1 to 100 do
      send ();
      ack 80
    done;
    finish ();
    ack 80;
    ack 80;
    require
      (!model.sent = 64 && !model.finished
      && !model.acked = String.length expected)
      "incomplete fair schedule")

let client_fragments bytes =
  let t = ok (E.client ()) in
  let request =
    Request.create ~meth:Method.get
      ~target:(value (Target.of_string "/"))
      ~headers:(value (Headers.of_list [ ("host", "x") ]))
      ()
  in
  let id =
    match ok (E.submit_request t request) with
    | E.Accepted id -> id
    | _ -> failwith "request backpressure"
  in
  ignore (ok (E.finish t id));
  let rec drain () =
    match E.output t with
    | None -> ()
    | Some (_, _, n) ->
        ignore (ok (E.acknowledge t n));
        drain ()
  in
  drain ();
  let wire =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
  in
  let received = Buffer.create 3 and complete = ref 0 and heads = ref 0 in
  let rec loop off iteration =
    require (iteration < 1000) "client made no progress";
    match E.poll_event t with
    | Some (E.Response (id', _)) ->
        require (E.equal_id id id') "cross-exchange response";
        incr heads;
        loop off (iteration + 1)
    | Some (E.Data (id', data)) ->
        require (E.equal_id id id') "cross-exchange body";
        Buffer.add_string received data;
        loop off (iteration + 1)
    | Some (E.Trailers _) -> loop off (iteration + 1)
    | Some (E.Complete id') ->
        require (E.equal_id id id') "cross-exchange completion";
        incr complete;
        off
    | Some _ -> failwith "unexpected client event"
    | None ->
        let step =
          if bytes = "" then 1
          else 1 + (Char.code bytes.[iteration mod String.length bytes] mod 32)
        in
        let n =
          ok (E.offer t wire ~off ~len:(min step (String.length wire - off)))
        in
        loop (off + n) (iteration + 1)
  in
  require
    (loop 0 0 = String.length wire
    && !heads = 1 && !complete = 1
    && Buffer.contents received = "abc")
    "client lifecycle mismatch"

(* Authored sequencing expectations: RFC 9110 sections 7.8, 9.3.6 and
   15.2, plus httpkit's strict framing and bodyless-handoff policy. *)
type client_kind =
  | Ordinary
  | Expect
  | Upgrade
  | Upgrade_body
  | Connect
  | Connect_body

type sequence_end = Final | Transfer | Reject of E.error | Eof

type sequence_case = {
  name : string;
  kind : client_kind;
  infos : int list;
  limit : int;
  tail : string;
  ending : sequence_end;
}

let info_wire status = Printf.sprintf "HTTP/1.1 %d Interim\r\n\r\n" status
let final_wire = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
let switch fields = "HTTP/1.1 101 Switching\r\n" ^ fields ^ "\r\n"
let selection p = "Connection: upgrade\r\nUpgrade: " ^ p ^ "\r\n"

let sequence_cases =
  let make ?(kind = Ordinary) ?(infos = []) ?(limit = 16) name tail ending =
    { name; kind; infos; limit; tail; ending }
  in
  [
    make "no-infos-limit-zero" ~limit:0 final_wire Final;
    make "interleaved-expect" ~kind:Expect
      ~infos:[ 103; 100; 102; 100; 103; 199 ]
      final_wire Final;
    make "expect-without-continue" ~kind:Expect ~infos:[ 103; 102 ] final_wire
      Final;
    make "exact-limit" ~infos:(List.init 16 (fun _ -> 103)) final_wire Final;
    make "over-limit"
      ~infos:(List.init 16 (fun _ -> 103))
      (info_wire 100) (Reject E.Resource_limit);
    make "zero-limit-reject" ~limit:0 (info_wire 103) (Reject E.Resource_limit);
    make "eof-before-final" ~infos:[ 100; 103 ] "" Eof;
    make "partial-final-eof" ~infos:[ 103 ] "HTTP/1.1 200" Eof;
    make "info-content-length" ~infos:[ 103 ]
      "HTTP/1.1 100 Continue\r\nContent-Length: 0\r\n\r\n"
      (Reject (E.Protocol Httpkit_http1.Ambiguous_framing));
    make "info-transfer-encoding" ~infos:[ 100 ]
      "HTTP/1.1 103 Hints\r\nTransfer-Encoding: chunked\r\n\r\n"
      (Reject (E.Protocol Httpkit_http1.Ambiguous_framing));
    make "upgrade-name-case" ~kind:Upgrade ~infos:[ 103; 100 ]
      (switch (selection "pRoTo/V1"))
      Transfer;
    make "upgrade-version-case" ~kind:Upgrade
      (switch (selection "proto/v1"))
      (Reject (E.Protocol Httpkit_http1.Invalid_field));
    make "upgrade-unoffered" ~kind:Upgrade
      (switch (selection "other"))
      (Reject (E.Protocol Httpkit_http1.Invalid_field));
    make "upgrade-multiple" ~kind:Upgrade
      (switch (selection "proto/V1, second"))
      (Reject (E.Protocol Httpkit_http1.Invalid_field));
    make "upgrade-malformed" ~kind:Upgrade
      (switch (selection "proto/V1/extra"))
      (Reject (E.Protocol Httpkit_http1.Invalid_field));
    make "upgrade-missing-nomination" ~kind:Upgrade
      (switch "Upgrade: proto/V1\r\n")
      (Reject (E.Protocol Httpkit_http1.Invalid_field));
    make "upgrade-missing-selection" ~kind:Upgrade
      (switch "Connection: upgrade\r\n")
      (Reject (E.Protocol Httpkit_http1.Invalid_field));
    make "upgrade-unsolicited"
      (switch (selection "proto/V1"))
      (Reject (E.Protocol Httpkit_http1.Invalid_field));
    make "upgrade-refused" ~kind:Upgrade final_wire Final;
    make "upgrade-unfinished-body" ~kind:Upgrade_body
      (switch (selection "proto/V1"))
      (Reject (E.Protocol Httpkit_http1.Invalid_state));
    make "upgrade-content-length" ~kind:Upgrade
      (switch (selection "proto/V1" ^ "Content-Length: 0\r\n"))
      (Reject (E.Protocol Httpkit_http1.Ambiguous_framing));
    make "connect-success" ~kind:Connect ~infos:[ 103 ]
      "HTTP/1.1 200 Established\r\n\r\n" Transfer;
    make "connect-other-success" ~kind:Connect
      "HTTP/1.1 299 Established\r\n\r\n" Transfer;
    make "connect-failed" ~kind:Connect
      "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n" Final;
    make "connect-unfinished-body" ~kind:Connect_body
      "HTTP/1.1 200 Established\r\n\r\n"
      (Reject (E.Protocol Httpkit_http1.Invalid_state));
  ]
  @ List.init 99 (fun i ->
      let status = if i = 0 then 100 else i + 101 in
      make
        (Printf.sprintf "informational-%d" status)
        ~infos:[ status ] final_wire Final)

let sequence_wire case =
  String.concat "" (List.map info_wire case.infos) ^ case.tail

let sequence_suffix =
  "HTTP/1.1 200 Intruder\r\nContent-Length: 0\r\n\r\n\000tunnel"

let sequence_input case =
  sequence_wire case ^ if case.ending = Eof then "" else sequence_suffix

(* [window] is an input segmentation schedule. A work limit may stop inside
   its current window; callers retain the exact suffix. [ack] selects queued,
   partially acknowledged, last-byte-pending or drained request headers. *)
let client_sequence case ~step ~ack ~window =
  let limits = value (Httpkit_http1.limits ~step ()) in
  let t = ok (E.client ~limits ~informational_limit:case.limit ()) in
  let meth, target, fields =
    match case.kind with
    | Ordinary -> (Method.get, "/", [ ("host", "x") ])
    | Expect ->
        ( Method.post,
          "/",
          [ ("host", "x"); ("content-length", "0"); ("expect", "100-continue") ]
        )
    | Upgrade | Upgrade_body ->
        ( Method.get,
          "/",
          [
            ("host", "x");
            ("connection", "upgrade");
            ("upgrade", "PROTO/V1, second");
          ]
          @ if case.kind = Upgrade_body then [ ("content-length", "1") ] else []
        )
    | Connect | Connect_body ->
        ( Method.connect,
          "x:443",
          [ ("host", "x:443") ]
          @ if case.kind = Connect_body then [ ("content-length", "1") ] else []
        )
  in
  let request =
    Request.create ~meth
      ~target:(value (Target.of_string target))
      ~headers:(value (Headers.of_list fields))
      ()
  in
  let id =
    match ok (E.submit_request t request) with
    | E.Accepted id -> id
    | _ -> failwith "sequence admission"
  in
  let finish () =
    require (E.finish t id = Ok (E.Accepted ())) "sequence finish"
  in
  if not (List.mem case.kind [ Expect; Connect_body; Upgrade_body ]) then
    finish ();
  let initial = E.queued_output_bytes t in
  let count =
    match ack mod 4 with 0 -> 0 | 1 -> 1 | 2 -> initial - 1 | _ -> initial
  in
  if count > 0 then ignore (ok (E.acknowledge t count));
  let pending = initial - count in
  let suffix = sequence_suffix in
  let head = sequence_wire case in
  let wire = sequence_input case in
  let seen = ref [] and response = ref false and complete = ref false in
  let transferred = ref false and closed = ref None and continued = ref false in
  let same id' = require (E.equal_id id id') "sequence association" in
  let rec events fuel =
    require (fuel > 0) "unbounded event polling";
    match E.poll_event t with
    | None -> ()
    | Some (E.Informational (id', r)) ->
        same id';
        require ((not !response) && not !complete) "informational event order";
        let status = Status.to_int (Response.status r) in
        seen := !seen @ [ status ];
        require
          (E.queued_output_bytes t = pending)
          "informational changed output";
        if case.kind = Expect && not !continued then
          if status = 100 then (
            finish ();
            continued := true)
          else
            require (E.finish t id = Ok E.Backpressured) "Expect released early";
        events (fuel - 1)
    | Some (E.Response (id', r)) ->
        same id';
        require ((not !response) && !seen = case.infos) "response order";
        require
          (Status.to_int (Response.status r) >= 200 || case.ending = Transfer)
          "unexpected final status";
        response := true;
        events (fuel - 1)
    | Some (E.Complete id') ->
        same id';
        require
          (!response && (not !complete) && case.ending = Final)
          "completion order";
        complete := true;
        events (fuel - 1)
    | Some (E.Handoff id') ->
        same id';
        require
          (!response && (not !transferred) && case.ending = Transfer
          && E.queued_output_bytes t = 0)
          "handoff order";
        transferred := true;
        events (fuel - 1)
    | Some (E.Closed reason) ->
        require (!closed = None) "duplicate closure";
        closed := Some reason;
        events (fuel - 1)
    | Some _ -> failwith "unexpected sequence event"
  in
  let rec feed pos fuel =
    require (fuel > 0) "sequence progress budget";
    events 8;
    if !response || !closed <> None then pos
    else if pos = String.length wire then (
      require (case.ending = Eof) "sequence lacked final event";
      require
        (E.input_eof t = Error (E.Protocol Httpkit_http1.Unexpected_eof))
        "EOF without final succeeded";
      events 8;
      pos)
    else
      let len = min (window pos) (String.length wire - pos) in
      match E.offer t wire ~off:pos ~len with
      | Ok n ->
          require
            (n > 0 && n <= min len step)
            "sequence input stalled/overconsumed";
          feed (pos + n) (fuel - 1)
      | Error e ->
          require (case.ending = Reject e) "wrong sequence failure";
          events 8;
          pos
  in
  let consumed = feed 0 (String.length wire + 4) in
  require (!seen = case.infos) "lost informational events";
  let terminal () =
    require
      (E.offer t suffix ~off:0 ~len:(String.length suffix)
      = Error E.Invalid_command)
      "terminal engine parsed suffix";
    require
      (E.submit_request t request = Error E.Invalid_command)
      "terminal reuse";
    require
      (E.poll_event t = None
      && E.queued_input_bytes t = 0
      && E.queued_output_bytes t = 0)
      "terminal retained work"
  in
  match case.ending with
  | (Reject _ | Eof) as ending ->
      let expected =
        match ending with
        | Reject e -> e
        | _ -> E.Protocol Httpkit_http1.Unexpected_eof
      in
      require
        (!closed = Some (Some expected) && (not !response) && not !complete)
        "failure lifecycle";
      E.abort t E.Cancelled;
      terminal ()
  | Transfer ->
      require
        (consumed = String.length head && (not !complete) && !closed = None)
        "handoff suffix/completion";
      if pending > 0 then (
        require
          ((not !transferred) && E.input_state t = `Blocked)
          "early handoff";
        require
          (E.offer t suffix ~off:0 ~len:(String.length suffix) = Ok 0)
          "pending handoff parsed suffix";
        require
          (E.acknowledge t (pending + 1) = Error E.Invalid_command)
          "invalid handoff acknowledgement";
        ignore (ok (E.acknowledge t pending)));
      events 8;
      require !transferred "missing handoff";
      terminal ()
  | Final ->
      require
        (consumed = String.length head && !complete && not !transferred)
        "final suffix/completion";
      let aborted = case.kind = Expect && not !continued in
      if aborted then (
        require (!closed = Some None) "unfinished Expect reused";
        terminal ())
      else (
        require (!closed = None) "persistent final closed";
        if pending > 0 then (
          require
            (E.submit_request t request = Ok E.Backpressured)
            "reuse before ack";
          ignore (ok (E.acknowledge t pending)));
        let next =
          match ok (E.submit_request t request) with
          | E.Accepted id -> id
          | _ -> failwith "missing reuse"
        in
        require (not (E.equal_id id next)) "reused identity";
        ignore (ok (E.continue_request t next));
        require (E.finish t next = Ok (E.Accepted ())) "second finish";
        let rec drain () =
          match E.output t with
          | None -> ()
          | Some (_, _, n) ->
              ignore (ok (E.acknowledge t n));
              drain ()
        in
        drain ();
        let next_wire =
          String.concat "" (List.map info_wire case.infos)
          ^ "HTTP/1.1 403 Refused\r\nContent-Length: 0\r\n\r\n"
        in
        let next_infos = ref []
        and next_response = ref false
        and next_complete = ref false in
        let rec receive pos fuel =
          require (fuel > 0) "second exchange stalled";
          match E.poll_event t with
          | Some (E.Informational (id', r)) ->
              require
                (E.equal_id next id' && not !next_response)
                "stale informational identity";
              next_infos := !next_infos @ [ Status.to_int (Response.status r) ];
              receive pos (fuel - 1)
          | Some (E.Response (id', r)) ->
              require
                (E.equal_id next id' && (not !next_response)
               && !next_infos = case.infos
                && Status.to_int (Response.status r) = 403)
                "second response association";
              next_response := true;
              receive pos (fuel - 1)
          | Some (E.Complete id') ->
              require
                (E.equal_id next id' && !next_response && (not !next_complete)
                && pos = String.length next_wire)
                "second completion";
              next_complete := true
          | Some _ -> failwith "unexpected second exchange event"
          | None ->
              let n =
                ok
                  (E.offer t next_wire ~off:pos
                     ~len:(String.length next_wire - pos))
              in
              require (n > 0 && n <= step) "second exchange progress";
              receive (pos + n) (fuel - 1)
        in
        receive 0 ((2 * String.length next_wire) + 8);
        require
          (!next_complete && E.poll_event t = None)
          "duplicate second completion";
        E.abort t E.Cancelled;
        require
          (E.poll_event t = Some (E.Closed (Some E.Cancelled)))
          "reuse cleanup";
        terminal ())

let client_sequences bytes =
  let byte i =
    if bytes = "" then 0 else Char.code bytes.[i mod String.length bytes]
  in
  let case = List.nth sequence_cases (byte 0 mod List.length sequence_cases) in
  let step = List.nth [ 1; 7; 16384 ] (byte 1 mod 3) in
  client_sequence case ~step ~ack:(byte 2) ~window:(fun pos ->
      1 + byte (pos + 3))
