(* Public server APIs, with both directions driven to their framing boundary.
   No sockets: input is caller-owned, output remains borrowed until acknowledged.
   The same codec oracle checks payloads, framing, response count and suffixes. *)
open Http_kit_core
open Suite_support
module E = Http_kit_engine
module H = Http_kit_http1
module B = Suite_external_body

type writer = { push : string -> bool; finish : unit -> bool }
type view = { length : int; get : int -> char }

type connection = {
  read : int -> int -> int;
  ready : unit -> bool;
  pump : unit -> unit;
  output : unit -> view option;
  ack : int -> unit;
  stop : unit -> unit;
}

let accepted = function
  | Ok (E.Accepted ()) -> true
  | Ok E.Backpressured -> false
  | Error e -> failwith (E.error_to_string e)

let fields chunked size =
  if chunked then [ ("transfer-encoding", "chunked") ]
  else [ ("content-length", string_of_int size) ]

let kit input _bigwire response_fields receive respond =
  let conn = ok (E.server ()) in
  let current = ref None in
  let pump () =
    match E.poll_event conn with
    | Some (E.Request (id, r)) ->
        require (Target.to_string (Request.target r) = "/body");
        current := Some id
    | Some (E.Data (_, s)) -> receive s
    | Some (E.Trailers (_, h)) -> require (Headers.length h = 0)
    | Some (E.Complete id) ->
        require (Option.exists (E.equal_id id) !current);
        require
          (accepted
             (E.respond conn id
                (Response.create ~status:Status.ok
                   ~headers:(ok (Headers.of_list response_fields))
                   ())));
        respond
          {
            push = (fun s -> accepted (E.send_data conn id s));
            finish = (fun () -> accepted (E.finish conn id));
          }
    | None -> ()
    | Some _ -> failwith "unexpected exchange event"
  in
  {
    read = (fun off len -> ok (E.offer conn input ~off ~len));
    ready =
      (fun () ->
        match E.input_state conn with
        | `Idle | `Head | `Body -> true
        | `Blocked | `Closed -> false);
    pump;
    output =
      (fun () ->
        Option.map
          (fun (s, off, len) -> { length = len; get = (fun i -> s.[off + i]) })
          (E.output conn));
    ack = (fun n -> ignore (ok (E.acknowledge conn n)));
    stop = (fun () -> E.abort conn E.Cancelled);
  }

let httpaf _input bigwire response_fields receive respond =
  let conn =
    Httpaf.Server_connection.create
      ~error_handler:(fun ?request:_ _ _ -> failwith "httpaf exchange error")
      (fun reqd ->
        let request = Httpaf.Reqd.request reqd in
        require (request.target = "/body");
        let body = Httpaf.Reqd.request_body reqd in
        let rec arm () =
          Httpaf.Body.schedule_read body
            ~on_read:(fun bs ~off ~len ->
              receive (Bigstringaf.substring bs ~off ~len);
              arm ())
            ~on_eof:(fun () ->
              let writer =
                Httpaf.Reqd.respond_with_streaming reqd
                  (Httpaf.Response.create
                     ~headers:(Httpaf.Headers.of_list response_fields)
                     `OK)
              in
              respond
                {
                  push =
                    (fun s ->
                      Httpaf.Body.write_string writer s;
                      true);
                  finish =
                    (fun () ->
                      Httpaf.Body.close_writer writer;
                      true);
                })
        in
        arm ())
  in
  {
    ready =
      (fun () -> Httpaf.Server_connection.next_read_operation conn = `Read);
    read = (fun off len -> Httpaf.Server_connection.read conn bigwire ~off ~len);
    pump = (fun () -> ());
    output =
      (fun () ->
        match Httpaf.Server_connection.next_write_operation conn with
        | `Write ({ buffer; off; len } :: _) ->
            Some
              {
                length = len;
                get = (fun i -> Bigstringaf.get buffer (off + i));
              }
        | _ -> None);
    ack = (fun n -> Httpaf.Server_connection.report_write_result conn (`Ok n));
    stop = (fun () -> Httpaf.Server_connection.shutdown conn);
  }

let httpun _input bigwire response_fields receive respond =
  let conn =
    Httpun.Server_connection.create
      ~error_handler:(fun ?request:_ _ _ -> failwith "httpun exchange error")
      (fun reqd ->
        require ((Httpun.Reqd.request reqd).target = "/body");
        let body = Httpun.Reqd.request_body reqd in
        let rec arm () =
          Httpun.Body.Reader.schedule_read body
            ~on_read:(fun bs ~off ~len ->
              receive (Bigstringaf.substring bs ~off ~len);
              arm ())
            ~on_eof:(fun () ->
              let writer =
                Httpun.Reqd.respond_with_streaming reqd
                  (Httpun.Response.create
                     ~headers:(Httpun.Headers.of_list response_fields)
                     `OK)
              in
              respond
                {
                  push =
                    (fun s ->
                      Httpun.Body.Writer.write_string writer s;
                      true);
                  finish =
                    (fun () ->
                      Httpun.Body.Writer.close writer;
                      true);
                })
        in
        arm ())
  in
  {
    ready =
      (fun () -> Httpun.Server_connection.next_read_operation conn = `Read);
    read = (fun off len -> Httpun.Server_connection.read conn bigwire ~off ~len);
    pump = (fun () -> ());
    output =
      (fun () ->
        match Httpun.Server_connection.next_write_operation conn with
        | `Write ({ buffer; off; len } :: _) ->
            Some
              {
                length = len;
                get = (fun i -> Bigstringaf.get buffer (off + i));
              }
        | _ -> None);
    ack = (fun n -> Httpun.Server_connection.report_write_result conn (`Ok n));
    stop = (fun () -> Httpun.Server_connection.shutdown conn);
  }

let verify_responses ~chunked wire body count =
  let offset = ref 0 in
  for _ = 1 to count do
    let head = H.head_decoder (H.Response Method.post) in
    let n, metadata =
      ok
        (H.feed_head head wire ~off:!offset ~len:(String.length wire - !offset))
    in
    offset := !offset + n;
    let metadata = Option.get metadata in
    require
      ((metadata.framing
       =
       if chunked then H.Chunked
       else H.Fixed (Int64.of_int (String.length body)))
      || ((not chunked) && body = "" && metadata.framing = H.Empty));
    (match metadata.head with
    | H.Response_head r -> require (Response.status r = Status.ok)
    | _ -> assert false);
    let decoder = H.body_decoder metadata in
    let ended = ref false and position = ref 0 in
    while not !ended do
      let n, event =
        ok
          (H.feed_body decoder wire ~off:!offset
             ~len:(String.length wire - !offset))
      in
      offset := !offset + n;
      match event with
      | Some (H.Data s) ->
          require (!position + String.length s <= String.length body);
          String.iteri (fun i c -> require (c = body.[!position + i])) s;
          position := !position + String.length s
      | Some H.End -> ended := true
      | Some (H.Trailers h) -> require (Headers.length h = 0)
      | None -> require (n > 0)
    done;
    require (!position = String.length body)
  done;
  require (!offset = String.length wire)

let run make input bigwire request_body response_body response_fields pieces
    count step ack () =
  let received = ref 0 and completed = ref 0 and sent = ref 0 in
  let active = ref None in
  let receive data =
    require (!received + String.length data <= String.length request_body);
    String.iteri (fun i c -> require (c = request_body.[!received + i])) data;
    received := !received + String.length data
  in
  let respond writer =
    require (!received = String.length request_body && !active = None);
    received := 0;
    incr completed;
    require (writer.push "");
    active := Some (writer, pieces)
  in
  let conn = make input bigwire response_fields receive respond in
  Fun.protect ~finally:conn.stop (fun () ->
      let offset = ref 0
      and ticks = ref 0
      and available = ref 0
      and need_more = ref true in
      let output =
        Buffer.create ((String.length response_body * count) + 1024)
      in
      let rec drain () =
        match conn.output () with
        | None -> ()
        | Some view ->
            let n = min ack view.length in
            require (n > 0);
            (* Re-poll before acknowledgement: the exposed prefix must remain
             stable. Only inspect the acknowledged prefix, avoiding quadratic
             copying when the transport accepts a single byte. *)
            let again = Option.get (conn.output ()) in
            require (again.length >= n);
            for i = 0 to n - 1 do
              let c = view.get i in
              require (c = again.get i);
              Buffer.add_char output c
            done;
            conn.ack n;
            drain ()
      in
      while !sent < count || !offset < String.length input do
        incr ticks;
        if !ticks >= (20 * String.length input) + (count * 10000) then
          failwith
            (Printf.sprintf "stalled: input %d/%d completed %d sent %d" !offset
               (String.length input) !completed !sent);
        conn.pump ();
        (match !active with
        | None -> ()
        | Some (writer, []) ->
            if writer.finish () then (
              active := None;
              incr sent)
        | Some (writer, s :: tail) ->
            if writer.push s then active := Some (writer, tail));
        drain ();
        (* A paused reader is not a parser requesting a longer prefix. Do not
           expose another arrival until it is ready; otherwise output stalls
           silently change the configured input fragmentation per library. *)
        if !offset < String.length input && conn.ready () then (
          if !need_more then
            available := min (String.length input) (!available + step);
          let n = conn.read !offset (!available - !offset) in
          require (n >= 0 && n <= !available - !offset);
          offset := !offset + n;
          need_more := n = 0 || !offset = !available)
      done;
      drain ();
      require (!completed = count && !received = 0 && !active = None);
      verify_responses
        ~chunked:(List.mem_assoc "transfer-encoding" response_fields)
        (Buffer.contents output) response_body count)

let check_oracle () =
  let good = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc" in
  verify_responses ~chunked:false good "abc" 1;
  let reject work =
    require
      (try
         work ();
         false
       with Failure _ -> true)
  in
  reject (fun () -> verify_responses ~chunked:false good "abd" 1);
  reject (fun () -> verify_responses ~chunked:false (good ^ "suffix") "abc" 1);
  reject (fun () -> verify_responses ~chunked:true good "abc" 1);
  reject (fun () -> verify_responses ~chunked:false (good ^ good) "abc" 1)

let check_paused_reader () =
  let fixture = B.fixture true B.Fixed 64 (B.Pieces 1) false false in
  let paused_kit input bigwire fields receive respond =
    let conn = kit input bigwire fields receive respond in
    let tick = ref 0 and allowed = ref false in
    {
      conn with
      ready =
        (fun () ->
          incr tick;
          allowed := !tick mod 3 <> 0 && conn.ready ();
          !allowed);
      read =
        (fun off len ->
          require (!allowed && len = 1);
          allowed := false;
          conn.read off len);
    }
  in
  run paused_kit fixture.wire fixture.bigwire fixture.body "ok" (fields false 2)
    [ "ok" ] 1 1 1 ()

let jobs () =
  check_oracle ();
  check_paused_reader ();
  List.concat_map
    (fun writer_only ->
      List.concat_map
        (fun chunked ->
          List.concat_map
            (fun size ->
              let fixture =
                B.fixture true
                  (if chunked then B.Chunked 17 else B.Fixed)
                  (if writer_only then 0 else size)
                  (B.Pieces 16384) false false
              in
              let body =
                String.init size (fun i -> Char.chr (((i * 31) + 7) land 255))
              in
              let rec split off =
                if off = size then []
                else
                  let n = min 8192 (size - off) in
                  String.sub body off n :: split (off + n)
              in
              let pieces = split 0 in
              List.concat_map
                (fun (count, step, ack) ->
                  let input =
                    String.concat "" (List.init count (fun _ -> fixture.wire))
                  in
                  let bigwire =
                    Bigstringaf.of_string ~off:0 ~len:(String.length input)
                      input
                  in
                  let comparison =
                    Printf.sprintf "%s/%s/bytes-%d/messages-%d/read-%d/ack-%d"
                      (if writer_only then "writer" else "exchange")
                      (if chunked then "chunked" else "fixed")
                      size count step ack
                  in
                  List.map
                    (fun (implementation, make) ->
                      let work =
                        run make input bigwire fixture.body body
                          (fields chunked size) pieces count step ack
                      in
                      (try work ()
                       with exn ->
                         failwith
                           (comparison ^ "/" ^ implementation ^ ": "
                          ^ Printexc.to_string exn));
                      job
                        ~bytes:(count * (size + String.length fixture.body))
                        ~comparison ~implementation "exchange"
                        ("external/" ^ comparison ^ "/" ^ implementation)
                        3 work)
                    [
                      ("http-kit", kit); ("httpaf", httpaf); ("httpun", httpun);
                    ])
                [ (1, 16384, 16384); (1, 1, 1); (8, 16384, 997) ])
            [ 0; 4096; 65536 ])
        [ false; true ])
    [ true; false ]
