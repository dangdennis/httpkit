module W = Httpkit

exception Protocol_error of string

let sse produce =
  App.stream
    ~headers:
      [
        ("content-type", "text/event-stream");
        ("cache-control", "no-cache");
        ("x-accel-buffering", "no");
      ]
    produce

let websocket ?max_frame ?max_message ~clock ?(idle_timeout = 30.)
    (transport : Httpkit_transport_eio.transport) suffix callback =
  if (not (Float.is_finite idle_timeout)) || idle_timeout <= 0. then
    invalid_arg "websocket timeout";
  let parser = W.Websocket.server ?max_frame ?max_message ()
  and closed = ref false
  and closing_since = ref None in
  let write event =
    let data =
      match W.Websocket.encode event with Ok s -> s | Error e -> invalid_arg e
    in
    let rec loop i =
      if i < String.length data then (
        let n = transport.write data i (String.length data - i) in
        if n <= 0 || n > String.length data - i then
          failwith "invalid websocket write";
        loop (i + n))
    in
    Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock idle_timeout)
      (fun () -> loop 0)
  in
  let consume input =
    match W.Websocket.feed parser input with
    | Error e ->
        write (W.Websocket.Close (Some 1002, "Protocol error"));
        closed := true;
        raise (Protocol_error e)
    | Ok events ->
        List.iter
          (fun event ->
            if not !closed then
              match event with
              | W.Websocket.Ping s -> write (W.Websocket.Pong s)
              | W.Websocket.Close (code, reason) ->
                  if !closing_since = None then
                    write (W.Websocket.Close (code, reason));
                  closed := true
              | _ when !closing_since <> None -> ()
              | event -> (
                  match
                    Eio.Time.Timeout.run_exn
                      (Eio.Time.Timeout.seconds clock idle_timeout) (fun () ->
                        callback event)
                  with
                  | None -> ()
                  | Some response -> (
                      write response;
                      match response with
                      | W.Websocket.Close _ ->
                          closing_since := Some (Eio.Time.Mono.now clock)
                      | _ -> ())))
          events
  in
  let rec initial i =
    if i < String.length suffix then (
      let n = min 65536 (String.length suffix - i) in
      consume (String.sub suffix i n);
      initial (i + n))
  in
  initial 0;
  let bytes = Bytes.create 8192 in
  while not !closed do
    let remaining =
      match !closing_since with
      | None -> idle_timeout
      | Some started ->
          idle_timeout
          -. Mtime.Span.to_float_ns
               (Mtime.span started (Eio.Time.Mono.now clock))
             /. 1e9
    in
    if remaining <= 0. then raise Eio.Time.Timeout;
    let n =
      Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock remaining)
        (fun () -> transport.read bytes 0 (Bytes.length bytes))
    in
    if n = 0 then (
      closed := true;
      match W.Websocket.eof parser with
      | Ok () -> ()
      | Error e -> raise (Protocol_error e))
    else if n < 0 || n > Bytes.length bytes then
      failwith "invalid websocket read"
    else consume (Bytes.sub_string bytes 0 n)
  done
