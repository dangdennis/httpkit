open Lwt.Infix
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

let websocket ?max_frame ?max_message ~(clock : Httpkit_transport_lwt.clock)
    ?(idle_timeout = 30.) (transport : Httpkit_transport_lwt.transport) suffix
    callback =
  if (not (Float.is_finite idle_timeout)) || idle_timeout <= 0. then
    invalid_arg "websocket timeout";
  let parser = W.Websocket.server ?max_frame ?max_message ()
  and closed = ref false
  and closing_since = ref None in
  let within seconds f =
    Lwt.pick
      [ f (); (clock.sleep seconds >>= fun () -> Lwt.fail Lwt_unix.Timeout) ]
  in
  let write event =
    let data =
      match W.Websocket.encode event with Ok s -> s | Error e -> invalid_arg e
    in
    let rec loop i =
      if i = String.length data then Lwt.return_unit
      else
        transport.write data i (String.length data - i) >>= fun n ->
        if n <= 0 || n > String.length data - i then
          Lwt.fail_with "invalid websocket write"
        else loop (i + n)
    in
    within idle_timeout (fun () -> loop 0)
  in
  let consume input =
    match W.Websocket.feed parser input with
    | Error e ->
        write (W.Websocket.Close (Some 1002, "Protocol error")) >>= fun () ->
        closed := true;
        Lwt.fail (Protocol_error e)
    | Ok events ->
        Lwt_list.iter_s
          (fun event ->
            if !closed then Lwt.return_unit
            else
              match event with
              | W.Websocket.Ping s -> write (W.Websocket.Pong s)
              | W.Websocket.Close (code, reason) ->
                  (if !closing_since = None then
                     write (W.Websocket.Close (code, reason))
                   else Lwt.return_unit)
                  >|= fun () -> closed := true
              | _ when !closing_since <> None -> Lwt.return_unit
              | event -> (
                  within idle_timeout (fun () -> callback event) >>= function
                  | None -> Lwt.return_unit
                  | Some response -> (
                      write response >|= fun () ->
                      match response with
                      | W.Websocket.Close _ ->
                          closing_since := Some (clock.now ())
                      | _ -> ())))
          events
  in
  let rec initial i =
    if i >= String.length suffix then Lwt.return_unit
    else
      let n = min 65536 (String.length suffix - i) in
      consume (String.sub suffix i n) >>= fun () -> initial (i + n)
  in
  let bytes = Bytes.create 8192 in
  let rec loop () =
    if !closed then Lwt.return_unit
    else
      let remaining =
        match !closing_since with
        | None -> idle_timeout
        | Some started -> idle_timeout -. (clock.now () -. started)
      in
      if remaining <= 0. then Lwt.fail Lwt_unix.Timeout
      else
        within remaining (fun () -> transport.read bytes 0 (Bytes.length bytes))
        >>= fun n ->
        if n = 0 then (
          closed := true;
          match W.Websocket.eof parser with
          | Ok () -> Lwt.return_unit
          | Error e -> Lwt.fail (Protocol_error e))
        else if n < 0 || n > Bytes.length bytes then
          Lwt.fail_with "invalid websocket read"
        else consume (Bytes.sub_string bytes 0 n) >>= loop
  in
  initial 0 >>= loop
