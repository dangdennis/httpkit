module W = Httpkit.Websocket

let frame opcode payload =
  let mask = "abcd" in
  String.make 1 (Char.chr (128 lor opcode))
  ^ String.make 1 (Char.chr (128 lor String.length payload))
  ^ mask
  ^ String.mapi
      (fun i c -> Char.chr (Char.code c lxor Char.code mask.[i mod 4]))
      payload

let eio () =
  Eio_mock.Backend.run_full (fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let start = Eio.Time.Mono.now clock in
      let writes = ref 0 and cleaned = ref false in
      let transport : Httpkit_transport_eio.transport =
        {
          read =
            (fun bytes off _ ->
              Eio.Time.Mono.sleep clock 1.;
              let ping = frame 9 "ping" in
              Bytes.blit_string ping 0 bytes off (String.length ping);
              String.length ping);
          write =
            (fun _ _ length ->
              incr writes;
              if !writes = 1 then length
              else
                Fun.protect
                  ~finally:(fun () -> cleaned := true)
                  Eio.Fiber.await_cancel);
          close = (fun () -> ());
        }
      in
      (try
         Httpkit_eio.Realtime.websocket ~clock ~idle_timeout:2. transport
           (frame 1 "bye") (fun _ -> Some (W.Close (None, "")));
         failwith "missing Eio closing timeout"
       with Eio.Time.Timeout -> ());
      if not !cleaned then failwith "Eio blocked pong cleanup not joined";
      Mtime.Span.to_float_ns (Mtime.span start (Eio.Time.Mono.now clock)) /. 1e9)

let () =
  let elapsed = eio () in
  Printf.printf "Closing deadline: Eio %.1fs, expected 2s\n%!" elapsed;
  if elapsed <> 2. then
    failwith "Pong write extended the absolute closing deadline";
  print_endline "PASS blocked pong respects WebSocket closing deadline"
