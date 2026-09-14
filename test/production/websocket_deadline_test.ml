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

let lwt () =
  let open Lwt.Infix in
  let writes = ref 0 and now = ref 0. and cleaned = ref false in
  let blocked, notify_blocked = Lwt.wait () in
  let deadline, expire = Lwt.task () in
  let clock : Httpkit_transport_lwt.clock =
    {
      now = (fun () -> !now);
      sleep =
        (fun duration ->
          if !writes = 2 then (
            Lwt.wakeup_later notify_blocked duration;
            deadline)
          else fst (Lwt.task ()));
    }
  in
  let transport : Httpkit_transport_lwt.transport =
    {
      read =
        (fun bytes off _ ->
          now := !now +. 1.;
          let ping = frame 9 "ping" in
          Bytes.blit_string ping 0 bytes off (String.length ping);
          Lwt.return (String.length ping));
      write =
        (fun _ _ length ->
          incr writes;
          if !writes = 1 then Lwt.return length
          else
            Lwt.finalize
              (fun () -> fst (Lwt.task ()))
              (fun () ->
                cleaned := true;
                Lwt.return_unit));
      close = (fun () -> Lwt.return_unit);
    }
  in
  let work =
    Httpkit_lwt.Realtime.websocket ~clock ~idle_timeout:2. transport
      (frame 1 "bye") (fun _ -> Lwt.return_some (W.Close (None, "")))
  in
  Lwt.finalize
    (fun () ->
      blocked >>= fun duration ->
      now := !now +. duration;
      Lwt.wakeup_later expire ();
      Lwt.catch
        (fun () ->
          work >>= fun () -> Lwt.fail_with "missing Lwt closing timeout")
        (function Lwt_unix.Timeout -> Lwt.return_unit | exn -> Lwt.fail exn)
      >|= fun () ->
      if not !cleaned then failwith "Lwt blocked pong cleanup not joined";
      !now)
    (fun () ->
      Lwt.cancel work;
      Lwt.catch (fun () -> work) (fun _ -> Lwt.return_unit))

let () =
  let eio_elapsed = eio () in
  let lwt_elapsed =
    Lwt_main.run (Lwt_unix.with_timeout 5. (fun () -> lwt ()))
  in
  Printf.printf "Closing deadline: Eio %.1fs, Lwt %.1fs, expected 2s\n%!"
    eio_elapsed lwt_elapsed;
  if eio_elapsed <> 2. || lwt_elapsed <> 2. then
    failwith "Pong write extended the absolute closing deadline";
  print_endline "PASS blocked pong respects WebSocket closing deadline"
