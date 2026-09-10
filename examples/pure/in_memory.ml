(* An application drives the same pure engines that the native adapters use.
   This example has no sockets, promises, clocks, or adapter dependencies. *)
open Http_kit_core
module E = Http_kit_engine

let checked = function
  | Ok value -> value
  | Error error -> failwith (E.error_to_string error)

let headers fields =
  match Headers.of_list fields with
  | Ok value -> value
  | Error _ -> failwith "invalid example headers"

let target value =
  match Target.of_string value with
  | Ok value -> value
  | Error _ -> failwith "invalid example target"

(* Transport acknowledges only bytes the receiving engine actually consumed.
   Three-byte fragments exercise incremental parsing and partial writes. A zero
   result means that the application must drain an event before retrying. *)
let transfer source destination =
  match E.output source with
  | None -> ()
  | Some (bytes, off, len) ->
      let consumed =
        checked (E.offer destination bytes ~off ~len:(min 3 len))
      in
      if consumed > 0 then checked (E.acknowledge source consumed)

let () =
  let client = checked (E.client ~output_limit:128 ()) in
  let server = checked (E.server ~output_limit:64 ()) in
  let request =
    Request.create ~meth:Method.get ~target:(target "/stream")
      ~headers:(headers [ ("host", "localhost") ])
      ()
  in
  let request_id =
    match checked (E.submit_request client request) with
    | E.Accepted id -> id
    | E.Backpressured -> failwith "request exceeds the example output budget"
  in
  (match checked (E.finish client request_id) with
  | E.Accepted () -> ()
  | E.Backpressured -> failwith "unexpected empty-request backpressure");
  let incoming = ref None in
  let writes = ref [] in
  let received = Buffer.create 32 in
  let complete = ref false in
  let response_seen = ref false in
  let steps = ref 0 in
  while not !complete do
    incr steps;
    if !steps > 10000 then failwith "exchange stopped making progress";
    transfer client server;
    (match E.poll_event server with
    | Some (E.Request (id, request)) -> incoming := Some (id, request)
    | Some (E.Complete id) ->
        let owner, request = Option.get !incoming in
        assert (E.equal_id owner id);
        let response =
          Response.create ~status:Status.ok
            ~headers:(headers [ ("transfer-encoding", "chunked") ])
            ()
        in
        (* Commands are queued as application work, not pre-encoded wire bytes.
           Chunk boundaries are an application choice. Only Accepted commands
           are removed: a Backpressured command has no effect and is retried. *)
        writes :=
          [ (fun () -> E.respond server id response) ]
          @ List.map
              (fun chunk () -> E.send_data server id chunk)
              [ "Hello "; Target.to_string (Request.target request); "\n" ]
          @ [ (fun () -> E.finish server id) ]
    | Some (E.Closed _) ->
        failwith "server closed before completing the exchange"
    | Some _ | None -> ());
    (match !writes with
    | [] -> ()
    | write :: rest -> (
        match checked (write ()) with
        | E.Accepted () -> writes := rest
        | E.Backpressured -> ()));
    transfer server client;
    match E.poll_event client with
    | Some (E.Response (id, response)) ->
        assert (E.equal_id id request_id);
        assert (Response.status response = Status.ok);
        response_seen := true
    | Some (E.Data (id, bytes)) ->
        assert (E.equal_id id request_id);
        (* Data is an owned chunk. This small example collects it; a streaming
           application could process it immediately and release it instead. *)
        Buffer.add_string received bytes
    | Some (E.Complete id) ->
        assert (E.equal_id id request_id);
        complete := true
    | Some (E.Closed _) ->
        failwith "client closed before completing the response"
    | Some _ | None -> ()
  done;
  assert !response_seen;
  assert (!writes = []);
  assert (Buffer.contents received = "Hello /stream\n");
  assert (E.queued_output_bytes server = 0);
  print_string (Buffer.contents received)
