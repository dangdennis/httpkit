open Httpkit_core
module E = Httpkit_engine
module C = Httpkit_http1
module S = Segmentation_support

let check = S.check
let ok = Engine_cases.ok
let accepted = Engine_cases.accepted

type progress = Waiting | Open | Finished of int

let acknowledge_prefix t count =
  let rec loop remaining =
    if remaining > 0 then
      match E.output t with
      | None -> failwith "acknowledgement exceeded output"
      | Some (_, _, len) ->
          let n = min remaining len in
          ignore (ok (E.acknowledge t n));
          loop (remaining - n)
  in
  loop count

let payload chunked =
  if chunked then "1\r\na\r\n1\r\nb\r\n1\r\nc\r\n" else "abc"

let upload chunked =
  payload chunked ^ if chunked then "0\r\ndigest: done\r\n\r\n" else ""

let scenario ~chunked ~progress ~closing ~close_delimited ~status ~step wire
    cuts =
  let t = ok (E.client ~limits:(S.ok (C.limits ~step ())) ()) in
  let fields =
    ("host", "x")
    ::
    (if chunked then [ ("transfer-encoding", "chunked"); ("trailer", "digest") ]
     else [ ("content-length", "3") ])
    @ if progress = Waiting then [ ("expect", "100-continue") ] else []
  in
  let id =
    accepted
      (ok (E.submit_request t (Engine_cases.request ~meth:Method.post fields)))
  in
  ignore (Engine_cases.drain ~step t);
  let remaining =
    match progress with
    | Waiting -> ""
    | Open | Finished _ -> (
        String.iter
          (fun c -> ignore (accepted (ok (E.send_data t id (String.make 1 c)))))
          "abc";
        match progress with
        | Finished acknowledged ->
            let trailers =
              if chunked then
                Engine_cases.value (Headers.of_list [ ("digest", "done") ])
              else Headers.empty
            in
            ignore (accepted (ok (E.finish ~trailers t id)));
            acknowledge_prefix t acknowledged;
            let bytes = upload chunked in
            String.sub bytes acknowledged (String.length bytes - acknowledged)
        | _ -> payload chunked)
  in
  let finalized = match progress with Finished _ -> true | _ -> false in
  let aborted = (not finalized) || (closing && remaining <> "") in
  let expected_output = if aborted then "" else remaining in
  let must_close = closing || aborted in
  check (E.queued_output_bytes t = String.length remaining) "initial queue";
  let pos = ref 0 and infos = ref 0 and responses = ref 0 in
  let complete = ref false and closed = ref false in
  let body = Buffer.create 3 in
  let same id' =
    check (E.equal_id id id') "response crossed exchange identity"
  in
  let rec events () =
    match E.poll_event t with
    | None -> ()
    | Some (E.Informational (id', r)) ->
        same id';
        incr infos;
        check
          (!infos = 1 && !responses = 0
          && Status.to_int (Response.status r) = 103)
          "informational ordering";
        check
          (E.queued_output_bytes t = String.length remaining)
          "informational response changed upload queue";
        if progress = Waiting then
          check
            (E.send_data t id "a" = Ok E.Backpressured)
            "103 released Expect gate";
        events ()
    | Some (E.Response (id', r)) ->
        same id';
        incr responses;
        check
          (!infos = 1 && !responses = 1
          && Status.to_int (Response.status r) = status)
          "final response ordering";
        check
          (E.queued_output_bytes t = String.length expected_output)
          "final response retained incorrect upload bytes";
        check
          (E.send_data t id "a" = Error E.Invalid_command)
          "final response admitted new upload data";
        check
          (E.finish t id = Error E.Invalid_command)
          "final response admitted finish";
        events ()
    | Some (E.Data (id', bytes)) ->
        same id';
        check (!responses = 1 && not !complete) "response body ordering";
        Buffer.add_string body bytes;
        events ()
    | Some (E.Complete id') ->
        same id';
        check (!responses = 1 && not !complete) "response completed twice";
        complete := true;
        events ()
    | Some (E.Closed reason) ->
        check
          (must_close && !complete && (not !closed) && reason = None)
          "unexpected or premature closure";
        closed := true;
        events ()
    | Some _ -> failwith "unexpected response lifecycle event"
  in
  let offered = S.window cuts (String.length wire) in
  let rec feed calls =
    check (calls <= String.length wire + 4) "response progress budget";
    events ();
    if (not !complete) && !pos = String.length wire then (
      check close_delimited "framed response failed to complete";
      ignore (ok (E.input_eof t));
      events ();
      check !complete "EOF failed to complete close-delimited response")
    else if not !complete then (
      let len = offered !pos in
      let n = ok (E.offer t wire ~off:!pos ~len) in
      check (n > 0 && n <= min step len) "response stalled or overconsumed";
      pos := !pos + n;
      feed (calls + 1))
  in
  feed 0;
  check
    (!pos
    = String.length wire - if close_delimited then 0 else String.length S.marker
    )
    "response consumed following message bytes";
  check
    (Buffer.contents body = "err")
    "response body lost during upload cancellation";
  let next = Engine_cases.request [ ("host", "x") ] in
  if must_close then (
    check !closed "closing response waited for cancelled output";
    check
      (E.submit_request t next = Error E.Invalid_command)
      "closed client reused";
    check
      (E.offer t S.marker ~off:0 ~len:(String.length S.marker)
      = Error E.Invalid_command)
      "closed client accepted suffix")
  else (
    if remaining <> "" then
      check
        (E.submit_request t next = Ok E.Backpressured)
        "client reused before upload acknowledgement";
    check
      (Engine_cases.drain ~step t = expected_output)
      "persistent final response changed finalized upload";
    let next_id = accepted (ok (E.submit_request t next)) in
    check (not (E.equal_id id next_id)) "client reused exchange identity";
    E.abort t E.Cancelled;
    check (E.poll_event t = Some (E.Closed (Some E.Cancelled))) "cleanup failed");
  check
    (E.queued_input_bytes t = 0 && E.queued_output_bytes t = 0)
    "retained queues";
  check (E.poll_event t = None) "duplicate terminal event"

let cases =
  List.concat_map
    (fun chunked ->
      let total = String.length (upload chunked) in
      List.concat_map
        (fun (stage, progress) ->
          List.concat_map
            (fun (mode, closing, close_delimited) ->
              List.map
                (fun status ->
                  let label =
                    Printf.sprintf "%s/%s/%s/%d"
                      (if chunked then "chunked" else "fixed")
                      stage mode status
                  in
                  let wire =
                    "HTTP/1.1 103 Early Hints\r\n\r\n"
                    ^ Printf.sprintf "HTTP/1.1 %d Test\r\n" status
                    ^ (if closing && not close_delimited then
                         "Connection: close\r\n"
                       else "")
                    ^
                    if close_delimited then "\r\nerr"
                    else "Content-Length: 3\r\n\r\nerr" ^ S.marker
                  in
                  Alcotest.test_case label `Quick (fun () ->
                      S.matrix label wire
                        (fun ~step cuts ->
                          scenario ~chunked ~progress ~closing ~close_delimited
                            ~status ~step wire cuts)
                        ()))
                [ 200; 413 ])
            [
              ("persistent", false, false);
              ("close", true, false);
              ("eof", true, true);
            ])
        [
          ("expect", Waiting);
          ("open", Open);
          ("queued", Finished 0);
          ("partial", Finished 1);
          ("last-byte", Finished (total - 1));
          ("drained", Finished total);
        ])
    [ false; true ]

let () = Alcotest.run "HTTP/1 client response sequencing" [ ("upload", cases) ]
