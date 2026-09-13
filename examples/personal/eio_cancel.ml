(* Cancel a blocked response read and verify that the owned transport closes. *)
module A = Http_kit_eio
module E = Http_kit_engine

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let flow, peer = Eio_unix.Net.socketpair_stream ~sw () in
          let clock = Eio.Stdenv.mono_clock env in
          let waiting, signal_waiting = Eio.Promise.create () in
          let transport = A.of_flow flow in
          let closed = ref 0 and active_reads = ref 0 in
          let transport =
            {
              transport with
              read =
                (fun bytes off len ->
                  incr active_reads;
                  Eio.Promise.resolve signal_waiting ();
                  Fun.protect
                    ~finally:(fun () -> decr active_reads)
                    (fun () -> transport.read bytes off len));
              close =
                (fun () ->
                  transport.close ();
                  incr closed);
            }
          in
          Eio.Fiber.first
            (fun () ->
              A.with_connection ~clock transport
                (Result.get_ok (E.server ()))
                (fun c -> ignore (A.next_event c)))
            (fun () -> Eio.Promise.await waiting);
          if !closed <> 1 || !active_reads <> 0 then
            failwith "cancelled work or transport survived its scope";
          Eio.Flow.close peer;
          print_endline "Cancelled read; transport closed once"))
