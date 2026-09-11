open Http_kit_core
open Suite_support
module E = Http_kit_engine
open Body_fixture

type progress = {
  mutable position : int;
  mutable data_events : int;
  mutable heads : int;
  mutable complete : int;
  mutable chunks : string list;
  mutable pending : (unit -> unit) option;
}

type driver = {
  read : off:int -> len:int -> eof:bool -> int;
  ready : unit -> bool;
  pump : unit -> unit;
  stop : unit -> unit;
}

let consume fixture progress data =
  progress.data_events <- progress.data_events + 1;
  let len = String.length data in
  require (len > 0 && progress.position + len <= String.length fixture.body);
  for i = 0 to len - 1 do
    check_byte ~offset:(progress.position + i)
      ~expected:fixture.body.[progress.position + i]
      ~actual:data.[i]
  done;
  progress.position <- progress.position + len;
  if fixture.config.consumption = Collect then
    progress.chunks <- data :: progress.chunks

(* The public upstream callback buffer is borrowed. Owned modes copy before
   scanning or retaining; borrowed mode scans inside the callback. Engine Data
   remains owned in every mode. One scheduled callback
   is consumed at a time; deferred mode rearms in the outer driver loop. *)
let attach fixture progress schedule =
  let rec arm () =
    schedule
      ~on_eof:(fun () -> progress.complete <- progress.complete + 1)
      ~on_read:(fun bs ~off ~len ->
        if fixture.config.consumption = Borrowed_scan then (
          progress.data_events <- progress.data_events + 1;
          require
            (len > 0 && progress.position + len <= String.length fixture.body);
          for i = 0 to len - 1 do
            require
              (Bigstringaf.get bs (off + i)
              = fixture.body.[progress.position + i])
          done;
          progress.position <- progress.position + len)
        else consume fixture progress (Bigstringaf.substring bs ~off ~len);
        if fixture.config.scheduling = Deferred then
          progress.pending <- Some arm
        else arm ())
  in
  arm ()

let pump_pending progress () =
  match progress.pending with
  | None -> ()
  | Some arm ->
      progress.pending <- None;
      arm ()

let httpaf fixture progress =
  let fail _ = failwith "httpaf public connection error" in
  let receive body =
    progress.heads <- progress.heads + 1;
    attach fixture progress (Httpaf.Body.schedule_read body)
  in
  if fixture.config.direction = Request then
    let conn =
      Httpaf.Server_connection.create
        ~error_handler:(fun ?request:_ error _ -> fail error)
        (fun reqd ->
          let request = Httpaf.Reqd.request reqd in
          require (request.meth = `POST && request.target = "/body");
          receive (Httpaf.Reqd.request_body reqd))
    in
    {
      read =
        (fun ~off ~len ~eof ->
          (if eof then Httpaf.Server_connection.read_eof
           else Httpaf.Server_connection.read)
            conn fixture.bigwire ~off ~len);
      ready =
        (fun () -> Httpaf.Server_connection.next_read_operation conn = `Read);
      pump = pump_pending progress;
      stop = (fun () -> Httpaf.Server_connection.shutdown conn);
    }
  else
    let request =
      Httpaf.Request.create
        ~headers:(Httpaf.Headers.of_list [ ("host", "x") ])
        `GET "/body"
    in
    let writer, conn =
      Httpaf.Client_connection.request request ~error_handler:fail
        ~response_handler:(fun response body ->
          require (response.status = `OK);
          receive body)
    in
    Httpaf.Body.close_writer writer;
    {
      read =
        (fun ~off ~len ~eof ->
          (if eof then Httpaf.Client_connection.read_eof
           else Httpaf.Client_connection.read)
            conn fixture.bigwire ~off ~len);
      ready =
        (fun () -> Httpaf.Client_connection.next_read_operation conn = `Read);
      pump = pump_pending progress;
      stop = (fun () -> Httpaf.Client_connection.shutdown conn);
    }

let httpun fixture progress =
  let fail _ = failwith "httpun public connection error" in
  let receive body =
    progress.heads <- progress.heads + 1;
    attach fixture progress (Httpun.Body.Reader.schedule_read body)
  in
  if fixture.config.direction = Request then
    let conn =
      Httpun.Server_connection.create
        ~error_handler:(fun ?request:_ error _ -> fail error)
        (fun reqd ->
          let request = Httpun.Reqd.request reqd in
          require (request.meth = `POST && request.target = "/body");
          receive (Httpun.Reqd.request_body reqd))
    in
    {
      read =
        (fun ~off ~len ~eof ->
          (if eof then Httpun.Server_connection.read_eof
           else Httpun.Server_connection.read)
            conn fixture.bigwire ~off ~len);
      ready =
        (fun () -> Httpun.Server_connection.next_read_operation conn = `Read);
      pump = pump_pending progress;
      stop = (fun () -> Httpun.Server_connection.shutdown conn);
    }
  else
    let conn = Httpun.Client_connection.create () in
    let request =
      Httpun.Request.create
        ~headers:(Httpun.Headers.of_list [ ("host", "x") ])
        `GET "/body"
    in
    let writer =
      Httpun.Client_connection.request conn request ~error_handler:fail
        ~response_handler:(fun response body ->
          require (response.status = `OK);
          receive body)
    in
    Httpun.Body.Writer.close writer;
    {
      read =
        (fun ~off ~len ~eof ->
          (if eof then Httpun.Client_connection.read_eof
           else Httpun.Client_connection.read)
            conn fixture.bigwire ~off ~len);
      ready =
        (fun () -> Httpun.Client_connection.next_read_operation conn = `Read);
      pump = pump_pending progress;
      stop = (fun () -> Httpun.Client_connection.shutdown conn);
    }

let kit fixture progress =
  let conn =
    ok (if fixture.config.direction = Request then E.server () else E.client ())
  in
  (if not (fixture.config.direction = Request) then
     let request =
       Request.create ~meth:Method.get
         ~target:(ok (Target.of_string "/body"))
         ~headers:(ok (Headers.of_list [ ("host", "x") ]))
         ()
     in
     let id =
       match
         ok ~error_to_string:E.error_to_string (E.submit_request conn request)
       with
       | E.Accepted id -> id
       | _ -> failwith "request backpressure"
     in
     require
       (ok ~error_to_string:E.error_to_string (E.finish conn id) = E.Accepted ()));
  let owner = ref None in
  let check_id id =
    match !owner with
    | Some expected -> require (E.equal_id expected id)
    | None -> failwith "body before head"
  in
  let pump () =
    match E.poll_event conn with
    | None -> ()
    | Some (E.Request (id, r)) ->
        require
          (fixture.config.direction = Request
          && Method.equal (Request.meth r) Method.post
          && Target.to_string (Request.target r) = "/body");
        owner := Some id;
        progress.heads <- progress.heads + 1
    | Some (E.Response (id, r)) ->
        require
          ((not (fixture.config.direction = Request))
          && Response.status r = Status.ok);
        owner := Some id;
        progress.heads <- progress.heads + 1
    | Some (E.Data (id, data)) ->
        check_id id;
        consume fixture progress data
    | Some (E.Trailers (id, fields)) ->
        check_id id;
        require (Headers.length fields = 0)
    | Some (E.Complete id) ->
        check_id id;
        progress.complete <- progress.complete + 1
    | Some _ -> failwith "unexpected engine body event"
  in
  {
    read =
      (fun ~off ~len ~eof ->
        let consumed =
          ok ~error_to_string:E.error_to_string
            (E.offer conn fixture.wire ~off ~len)
        in
        if eof && consumed = len then
          ignore (ok ~error_to_string:E.error_to_string (E.input_eof conn));
        consumed);
    ready =
      (fun () ->
        match E.input_state conn with
        | `Idle | `Head | `Body -> true
        | `Blocked | `Closed -> false);
    pump;
    stop = (fun () -> E.abort conn E.Cancelled);
  }

exception Body_eof_before_framing of int * int

let run ?(observe = fun ~data_events:_ ~reads:_ ~ticks:_ -> ()) fixture make ()
    =
  let progress =
    {
      position = 0;
      data_events = 0;
      heads = 0;
      complete = 0;
      chunks = [];
      pending = None;
    }
  in
  let conn = make fixture progress in
  let window = Input_window.create () in
  let arrival = ref 0
  and eof_sent = ref false
  and ticks = ref 0
  and reads = ref 0 in
  try
    Fun.protect ~finally:conn.stop (fun () ->
        while
          progress.complete = 0 || window.offset < String.length fixture.wire
        do
          incr ticks;
          require (!ticks <= (10 * String.length fixture.wire) + 1000);
          if (not (fixture.config.scheduling = Deferred)) || !ticks mod 2 = 0
          then conn.pump ();
          let ready = conn.ready () in
          if
            progress.complete = 1
            && window.offset < String.length fixture.wire
            && not ready
          then (
            require
              (progress.heads = 1
              && progress.position = String.length fixture.body);
            raise
              (Body_eof_before_framing
                 (window.offset, String.length fixture.wire)));
          if
            (progress.complete = 0 || window.offset < String.length fixture.wire)
            && ready
          then (
            if window.need_more && !arrival < Array.length fixture.arrivals then (
              Input_window.expose window fixture.arrivals.(!arrival);
              incr arrival);
            let eof =
              !arrival = Array.length fixture.arrivals
              && window.available = String.length fixture.wire
              && fixture.config.framing = Close
            in
            (* Only close-delimited bodies receive EOF here. Fixed/chunked bodies
           must complete from framing; an empty feed never substitutes for EOF. *)
            require (not !eof_sent);
            incr reads;
            let n =
              conn.read ~off:window.offset
                ~len:(window.available - window.offset)
                ~eof
            in
            Input_window.consume window n;
            if eof && window.offset = String.length fixture.wire then
              eof_sent := true)
        done;
        require
          (progress.complete = 1 && progress.heads = 1
          && progress.position = String.length fixture.body
          && window.offset = String.length fixture.wire);
        if fixture.config.consumption = Collect then
          require (String.concat "" (List.rev progress.chunks) = fixture.body);
        observe ~data_events:progress.data_events ~reads:!reads ~ticks:!ticks)
  with
  | Body_eof_before_framing _ as exn -> raise exn
  | exn ->
      failwith
        (Printf.sprintf
           "%s (input %d/%d, body %d/%d, heads %d, EOF events %d, ticks %d)"
           (Printexc.to_string exn) window.offset
           (String.length fixture.wire)
           progress.position
           (String.length fixture.body)
           progress.heads progress.complete !ticks)

let jobs ?(select = fun _ -> true) ?(preflight = true) () =
  let basic =
    List.concat_map
      (fun direction ->
        let framings =
          [ Fixed; Chunked 17; Chunked 8192 ]
          @ if direction = Request then [] else [ Close ]
        in
        List.concat_map
          (fun framing ->
            List.concat_map
              (fun size ->
                List.map
                  (fun transport ->
                    {
                      direction;
                      framing;
                      size;
                      transport;
                      scheduling = Immediate;
                      consumption = Owned_scan;
                    })
                  [ Pieces 64; Pieces 16384 ])
              [ 0; 64; 4096; 65536; 1048576 ])
          framings)
      [ Request; Response ]
  in
  let fragmented =
    List.concat_map
      (fun direction ->
        List.concat_map
          (fun size ->
            List.map
              (fun framing ->
                {
                  direction;
                  framing;
                  size;
                  transport = Pieces 1;
                  scheduling = Immediate;
                  consumption = Owned_scan;
                })
              ([ Fixed; Chunked 1; Chunked 17; Chunked 8192 ]
              @ if direction = Request then [] else [ Close ]))
          [ 64; 4096 ])
      [ Request; Response ]
  in
  let variants =
    List.concat_map
      (fun direction ->
        List.concat_map
          (fun size ->
            List.concat_map
              (fun framing ->
                [
                  {
                    direction;
                    framing;
                    size;
                    transport = Irregular;
                    scheduling = Immediate;
                    consumption = Owned_scan;
                  };
                  {
                    direction;
                    framing;
                    size;
                    transport = Pieces 16384;
                    scheduling = Deferred;
                    consumption = Owned_scan;
                  };
                  {
                    direction;
                    framing;
                    size;
                    transport = Pieces 16384;
                    scheduling = Immediate;
                    consumption = Collect;
                  };
                  {
                    direction;
                    framing;
                    size;
                    transport = Pieces 16384;
                    scheduling = Deferred;
                    consumption = Collect;
                  };
                ])
              ([ Fixed; Chunked 17 ]
              @ if direction = Request then [] else [ Close ]))
          [ 4096; 65536 ])
      [ Request; Response ]
  in
  List.concat_map
    (fun config ->
      let { direction; framing; size; transport; scheduling; consumption } =
        config
      in
      let framing_name =
        match framing with
        | Fixed -> "fixed"
        | Close -> "close"
        | Chunked n -> "chunk-" ^ string_of_int n
      in
      let transport_name =
        match transport with
        | Pieces n -> "step-" ^ string_of_int n
        | Irregular -> "irregular"
      in
      let comparison =
        Printf.sprintf "%s/%s/bytes-%d/%s/%s/%s"
          (if direction = Request then "request" else "response")
          framing_name size transport_name
          (if scheduling = Deferred then "deferred" else "immediate")
          (match consumption with
          | Collect -> "collect"
          | Borrowed_scan -> "borrowed-scan"
          | Owned_scan -> "owned-scan")
      in
      if
        not
          (select_group select "body" comparison
             [ "http-kit"; "httpaf"; "httpun" ])
      then []
      else
        let prepared = lazy (fixture config) in
        let iterations = max 1 (min 50 (262144 / max 64 (wire_size config))) in
        let implementations =
          [ ("http-kit", kit); ("httpaf", httpaf); ("httpun", httpun) ]
        in
        let incompatible =
          if not preflight then []
          else
            List.filter_map
              (fun (implementation, make) ->
                try
                  run (Lazy.force prepared) make ();
                  None
                with Body_eof_before_framing (consumed, total) ->
                  if implementation = "http-kit" then
                    failwith "reference engine completed before framing";
                  Some
                    (`Assoc
                       [
                         ("implementation", `String implementation);
                         ("consumed_bytes", `Int consumed);
                         ("wire_bytes", `Int total);
                         ( "reason",
                           `String
                             "Body EOF before full framing; public reader \
                              paused" );
                       ]))
              implementations
        in
        if incompatible <> [] then (
          exclusions :=
            `Assoc
              [
                ("family", `String "body");
                ("comparison", `String comparison);
                ( "excluded_implementations",
                  `List
                    [ `String "http-kit"; `String "httpaf"; `String "httpun" ]
                );
                ("observations", `List incompatible);
              ]
            :: !exclusions;
          [])
        else
          List.map
            (fun (implementation, make) ->
              job ~bytes:size ~comparison ~implementation "body"
                ("external/" ^ comparison ^ "/" ^ implementation)
                iterations
                (fun () -> run (Lazy.force prepared) make ()))
            implementations)
    (basic @ fragmented @ variants
    @ List.concat_map
        (fun direction ->
          List.concat_map
            (fun framing ->
              List.map
                (fun size ->
                  {
                    direction;
                    framing;
                    size;
                    transport = Pieces 16384;
                    scheduling = Immediate;
                    consumption = Borrowed_scan;
                  })
                [ 4096; 65536; 1048576 ])
            [ Fixed; Chunked 17; Chunked 8192 ])
        [ Request; Response ])

(* Single-fixture diagnostic entrypoint: separate process, no catalog-wide
   fixtures retained. OS stack sampling and peak RSS belong to this diagnostic
   process, never to the ordinary timing comparison. *)
let profile selection iterations =
  let implementation, mode =
    match String.split_on_char '/' selection with
    | [ a; b ] -> (a, b)
    | _ -> failwith "profile requires implementation/mode"
  in
  let make =
    match implementation with
    | "http-kit" -> kit
    | "httpaf" -> httpaf
    | "httpun" -> httpun
    | _ -> failwith "unknown profile implementation"
  in
  require
    (List.mem mode [ "owned-scan"; "borrowed-scan"; "collect" ]
    && iterations > 0 && iterations <= 10000);
  let consumption =
    match mode with
    | "collect" -> Collect
    | "borrowed-scan" -> Borrowed_scan
    | _ -> Owned_scan
  in
  let fixture =
    fixture
      {
        direction = Request;
        framing = Chunked 17;
        size = 65536;
        transport = Pieces 16384;
        scheduling = Immediate;
        consumption;
      }
  in
  let events = ref 0 and reads = ref 0 and ticks = ref 0 in
  let observe ~data_events ~reads:r ~ticks:t =
    events := data_events;
    reads := r;
    ticks := t
  in
  run ~observe fixture make ();
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  let clock = Mtime_clock.counter () in
  for _ = 1 to iterations do
    run fixture make ()
  done;
  let elapsed = Mtime.Span.to_float_ns (Mtime_clock.count clock) in
  let allocated = Gc.allocated_bytes () -. before in
  Gc.full_major ();
  let heap = Gc.stat () in
  (* Keep the fixture reachable through this snapshot, including its external
     Bigarray. live_words is the whole OCaml heap, not body-only retention. *)
  require (String.length (Sys.opaque_identity fixture).body = 65536);
  `Assoc
    [
      ("implementation", `String implementation);
      ("mode", `String mode);
      ("iterations", `Int iterations);
      ("payload_bytes", `Int 65536);
      ("wire_bytes", `Int (String.length fixture.wire));
      ("fixture_bigarray_bytes", `Int (Bigstringaf.length fixture.bigwire));
      ("data_events_per_op", `Int !events);
      ("read_calls_per_op", `Int !reads);
      ("driver_ticks_per_op", `Int !ticks);
      ("ns_per_op", `Float (elapsed /. float iterations));
      ("allocated_bytes_per_op", `Float (allocated /. float iterations));
      ("post_collection_live_words", `Int heap.live_words);
    ]
