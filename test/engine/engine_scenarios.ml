open Http_kit_core
module E = Http_kit_engine

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
      | Error (E.Protocol Http_kit_http1.Invalid_length) ->
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
