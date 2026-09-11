open Http_kit_core
open Suite_support
module E = Http_kit_engine

let accepted = function
  | Ok (E.Accepted value) -> value
  | _ -> failwith "unexpected backpressure"

let drain engine ~ack expected offset =
  let rec loop () =
    match E.output engine with
    | None -> ()
    | Some (wire, off, len) ->
        require (E.queued_output_bytes engine <= 32768);
        let n = min ack len in
        require (!offset + n <= String.length expected);
        for i = 0 to n - 1 do
          require (wire.[off + i] = expected.[!offset + i])
        done;
        ignore (ok (E.acknowledge engine n));
        offset := !offset + n;
        loop ()
  in
  loop ()

(* These policy cases are deliberately kit-only: automatic Expect/early-final
   behavior is not equivalent across public upstream APIs. *)
let protocol_jobs () =
  List.concat_map
    (fun size ->
      let body = String.make size 'a' in
      let request =
        Request.create ~meth:Method.post
          ~target:(ok (Target.of_string "/body"))
          ~headers:
            (ok
               (Headers.of_list
                  [
                    ("host", "x");
                    ("content-length", string_of_int size);
                    ("expect", "100-continue");
                  ]))
          ()
      in
      let head, _ = ok (Http_kit_http1.encode_request request) in
      List.map
        (fun early ->
          job
            ~bytes:(if early then 0 else size)
            "engine"
            (Printf.sprintf "policy/%s/bytes-%d"
               (if early then "early-final" else "100-continue")
               size)
            20
            (fun () ->
              let conn = ok (E.client ()) in
              let id = accepted (E.submit_request conn request) in
              let sent = ref 0 in
              drain conn ~ack:997 head sent;
              require (!sent = String.length head);
              require
                (ok (E.send_data conn id body) = E.Backpressured
                && E.output conn = None);
              if not early then (
                let wire = "HTTP/1.1 100 Continue\r\n\r\n" in
                require
                  (ok (E.offer conn wire ~off:0 ~len:(String.length wire))
                  = String.length wire);
                (match E.poll_event conn with
                | Some (E.Informational (other, r)) ->
                    require
                      (E.equal_id id other
                      && Status.to_int (Response.status r) = 100)
                | _ -> failwith "missing continue");
                accepted (E.send_data conn id body);
                accepted (E.finish conn id);
                let sent = ref 0 in
                drain conn ~ack:997 body sent;
                require (!sent = size));
              let wire =
                if early then
                  "HTTP/1.1 413 Too Large\r\nContent-Length: 0\r\n\r\n"
                else "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
              in
              require
                (ok (E.offer conn wire ~off:0 ~len:(String.length wire))
                = String.length wire);
              (match E.poll_event conn with
              | Some (E.Response (other, r)) ->
                  require
                    (E.equal_id id other
                    && Status.to_int (Response.status r)
                       = if early then 413 else 200)
              | _ -> failwith "missing final");
              require
                (E.poll_event conn = Some (E.Complete id)
                && E.output conn = None);
              if early then require (E.poll_event conn = Some (E.Closed None));
              E.abort conn E.Cancelled))
        [ false; true ])
    [ 4096; 16384 ]

let jobs () =
  let input = "GET / HTTP/1.1\r\nHost: x\r\n\r\n" in
  let server =
    List.concat_map
      (fun size ->
        let body = String.make size 'a' in
        let response =
          Response.create ~status:Status.ok
            ~headers:
              (ok (Headers.of_list [ ("content-length", string_of_int size) ]))
            ()
        in
        let header, _ =
          ok
            (Http_kit_http1.encode_response ~request_method:Method.get response)
        in
        let expected = header ^ body in
        List.map
          (fun ack ->
            job ~bytes:size "engine"
              (Printf.sprintf "server/bytes-%d/ack-%d" size ack) 20 (fun () ->
                let engine = ok (E.server ~output_limit:32768 ()) in
                require
                  (ok (E.offer engine input ~off:0 ~len:(String.length input))
                  = String.length input);
                let id =
                  match E.poll_event engine with
                  | Some (E.Request (id, _)) -> id
                  | _ -> failwith "missing request"
                in
                require (E.poll_event engine = Some (E.Complete id));
                accepted (E.respond engine id response);
                let offset = ref 0 in
                let drain () = drain engine ~ack expected offset in
                let rec send off =
                  if off < size then
                    let n = min 8192 (size - off) in
                    let data = String.sub body off n in
                    match E.send_data engine id data with
                    | Ok (E.Accepted ()) -> send (off + n)
                    | Ok E.Backpressured ->
                        drain ();
                        send off
                    | _ -> failwith "engine send failed"
                in
                send 0;
                drain ();
                accepted (E.finish engine id);
                drain ();
                require
                  (!offset = String.length expected
                  && E.input_state engine = `Idle)))
          [ 1; 997; 16384 ])
      [ 0; 4096; 65536 ]
  in
  let request =
    Request.create ~meth:Method.get
      ~target:(ok (Target.of_string "/"))
      ~headers:(ok (Headers.of_list [ ("host", "x") ]))
      ()
  in
  let request_wire, _ = ok (Http_kit_http1.encode_request request) in
  let client =
    List.map
      (fun step ->
        let size = 4096 in
        let wire =
          "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n"
          ^ String.make size 'a'
        in
        job ~bytes:size "engine"
          (Printf.sprintf "client/bytes-%d/step-%d" size step) 20 (fun () ->
            let engine = ok (E.client ~output_limit:32768 ()) in
            let id = accepted (E.submit_request engine request) in
            accepted (E.finish engine id);
            let sent = ref 0 in
            drain engine ~ack:16384 request_wire sent;
            require (!sent = String.length request_wire);
            let offset = ref 0
            and total = ref 0
            and heads = ref 0
            and complete = ref false in
            while not !complete do
              match E.poll_event engine with
              | Some (E.Response (event_id, response)) ->
                  require
                    (E.equal_id id event_id
                    && Response.status response = Status.ok);
                  incr heads
              | Some (E.Data (event_id, data)) ->
                  require
                    (E.equal_id id event_id && String.for_all (( = ) 'a') data);
                  total := !total + String.length data
              | Some (E.Complete event_id) ->
                  require (E.equal_id id event_id);
                  complete := true
              | Some _ -> failwith "unexpected client event"
              | None ->
                  require (!offset < String.length wire);
                  let n =
                    ok
                      (E.offer engine wire ~off:!offset
                         ~len:(min step (String.length wire - !offset)))
                  in
                  require (n > 0);
                  offset := !offset + n
            done;
            require (!heads = 1 && !total = size && !offset = String.length wire)))
      [ 1; 64; 16384 ]
  in
  server @ client @ protocol_jobs ()
