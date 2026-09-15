(* Dedicated local stress fixture. No credentials, DB, public deployment or
   unbounded event history; the observation file is owned by the test runner. *)
module App = Httpkit_eio
module A = Httpkit_transport_eio
module O = Httpkit.Observation

let stream_bytes = 8 * 1024 * 1024
let chunk = String.make 8192 'x'

type connection = {
  id : int;
  mutable written : int;
  mutable produced : int;
  mutable producing : bool;
  mutable sending : bool;
  mutable last_write : float;
}

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let clock = Eio.Stdenv.mono_clock env in
          let now () =
            Int64.to_float (Mtime.to_uint64_ns (Eio.Time.Mono.now clock)) /. 1e9
          in
          let capacity = int_of_string (Sys.getenv "HTTPKIT_MAX_CONNECTIONS") in
          if not (List.mem capacity [ 1; 16; 64 ]) then invalid_arg "capacity";
          let file = Sys.getenv "HTTPKIT_STRESS_SNAPSHOT" in
          let connections = Hashtbl.create capacity
          and queues = Hashtbl.create capacity in
          let recent_closed = Queue.create () in
          let opened = ref 0
          and closed = ref 0
          and peak = ref 0
          and unexpected = ref 0
          and violations = ref 0
          and queue_peak = ref 0
          and finished = ref 0
          and failed = ref 0
          and requests = ref 0 in
          let failures = Hashtbl.create 8 in
          let failure_name = function
            | O.Timeout O.Header -> "header"
            | Timeout Body -> "body"
            | Timeout Write -> "write"
            | Timeout Idle -> "idle"
            | Timeout Shutdown -> "shutdown"
            | Timeout Application -> "application"
            | Cancelled -> "cancelled"
            | Protocol_error -> "protocol"
            | Transport_error | Client_disconnected -> "disconnect"
            | Resource_limit -> "resource"
            | Application_error | Mixed_failure -> "unexpected"
          in
          let observe = function
            | O.Connection_accepted { connection; _ } ->
                if Hashtbl.length queues >= capacity then incr violations
                else Hashtbl.replace queues connection 0
            | Output_queue_changed { connection; queued_bytes } ->
                queue_peak := max !queue_peak queued_bytes;
                if
                  queued_bytes < 0 || queued_bytes > 32768
                  || not (Hashtbl.mem queues connection)
                then incr violations
                else Hashtbl.replace queues connection queued_bytes
            | Connection_closed { connection; close_status; _ } ->
                if close_status <> O.Closed then incr violations;
                Hashtbl.remove queues connection
            | Connection_failed { failure; _ } ->
                let key = failure_name failure in
                Hashtbl.replace failures key
                  (1 + Option.value ~default:0 (Hashtbl.find_opt failures key))
            | Request_started _ -> incr requests
            | _ -> ()
          in
          let rec on_error = function
            | Eio.Exn.Multiple errors ->
                List.iter (fun (e, _) -> on_error e) errors
            | A.Error (A.Timeout _ | A.Engine _ | A.Transport _) | End_of_file
              ->
                ()
            | Eio.Cancel.Cancelled _ -> ()
            | _ -> incr unexpected
          in
          let snapshot ?(gc = false) () =
            if gc then Gc.full_major ();
            let stat = Gc.stat () in
            let rows =
              Hashtbl.fold
                (fun _ c rows ->
                  `Assoc
                    [
                      ("id", `Int c.id);
                      ("written", `Int c.written);
                      ("produced", `Int c.produced);
                      ("producing", `Bool c.producing);
                      ("sending", `Bool c.sending);
                      ("last_write_seconds", `Float c.last_write);
                    ]
                  :: rows)
                connections []
            in
            `Assoc
              [
                ("opened", `Int !opened);
                ("snapshot_seconds", `Float (now ()));
                ("closed", `Int !closed);
                ("active", `Int (Hashtbl.length connections));
                ("peak_active", `Int !peak);
                ("unexpected_errors", `Int !unexpected);
                ("violations", `Int !violations);
                ("live_words", `Int stat.live_words);
                ("heap_words", `Int stat.heap_words);
                ("connections", `List rows);
                ( "closed_connections",
                  `List (List.of_seq (Queue.to_seq recent_closed)) );
                ( "queues",
                  `List (Hashtbl.fold (fun _ n xs -> `Int n :: xs) queues []) );
                ("queue_peak", `Int !queue_peak);
                ("producer_finished", `Int !finished);
                ("producer_failed", `Int !failed);
                ("requests", `Int !requests);
                ( "failures",
                  `Assoc
                    (Hashtbl.fold (fun k n xs -> (k, `Int n) :: xs) failures [])
                );
                ("stream_bytes", `Int stream_bytes);
                ("ocaml_version", `String Sys.ocaml_version);
                ("runtime", `String "eio");
                ("max_connections", `Int capacity);
              ]
          in
          let publish () =
            let out =
              Unix.openfile (file ^ ".tmp")
                [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
                0o600
              |> Unix.out_channel_of_descr
            in
            Fun.protect
              ~finally:(fun () -> close_out out)
              (fun () ->
                output_string out (Yojson.Safe.to_string (snapshot ())));
            Unix.rename (file ^ ".tmp") file
          in
          let reply text = App.reply (Httpkit.Reply.text text) in
          let handler request =
            match
              Httpkit_core.Target.to_string
                (Httpkit_core.Request.target (App.head request))
            with
            | "/health" -> reply "ok\n"
            | "/stats" -> App.reply (Httpkit.Reply.json (snapshot ~gc:true ()))
            | "/bench-stats" -> App.reply (Httpkit.Reply.json (snapshot ()))
            | "/ignore" -> reply "ignored\n"
            | "/blocked" ->
                let c =
                  Hashtbl.find connections (int_of_string (App.peer request))
                in
                App.stream (fun send ->
                    c.producing <- true;
                    Fun.protect
                      ~finally:(fun () ->
                        c.producing <- false;
                        c.sending <- false)
                      (fun () ->
                        try
                          for _ = 1 to stream_bytes / String.length chunk do
                            c.sending <- true;
                            send chunk;
                            c.sending <- false;
                            c.produced <- c.produced + String.length chunk
                          done;
                          incr finished
                        with exn ->
                          incr failed;
                          raise exn))
            | _ -> App.reply (Httpkit.Reply.text ~status:404 "not found\n")
          in
          let clock = Eio.Stdenv.mono_clock env in
          let socket =
            Eio.Net.listen ~sw ~reuse_addr:true ~backlog:128
              (Eio.Stdenv.net env)
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let stop, notify = Eio.Promise.create () and signalled = ref false in
          let signal _ =
            if not !signalled then (
              signalled := true;
              Eio.Promise.resolve notify ())
          in
          let old_term = Sys.signal Sys.sigterm (Sys.Signal_handle signal)
          and old_int = Sys.signal Sys.sigint (Sys.Signal_handle signal) in
          Fun.protect
            ~finally:(fun () ->
              Sys.set_signal Sys.sigterm old_term;
              Sys.set_signal Sys.sigint old_int)
            (fun () ->
              let port =
                match Eio.Net.listening_addr socket with
                | `Tcp (_, port) -> port
                | _ -> assert false
              in
              publish ();
              Printf.printf "LISTEN %d\n%!" port;
              Eio.Fiber.first
                (fun () ->
                  App.serve ~max_connections:capacity ~clock ~stop ~observe
                    ~on_error
                    ~random:(fun n -> String.make n 'x')
                    ~accept:(fun () ->
                      let flow, _ = Eio.Net.accept ~sw socket in
                      let transport = A.of_flow flow in
                      incr opened;
                      let c =
                        {
                          id = !opened;
                          written = 0;
                          produced = 0;
                          producing = false;
                          sending = false;
                          last_write = now ();
                        }
                      in
                      Hashtbl.add connections c.id c;
                      peak := max !peak (Hashtbl.length connections);
                      let closed_once = ref false in
                      ( {
                          transport with
                          write =
                            (fun b off len ->
                              let n = transport.write b off len in
                              c.written <- c.written + n;
                              if n > 0 then c.last_write <- now ();
                              n);
                          close =
                            (fun () ->
                              if !closed_once then incr violations
                              else (
                                closed_once := true;
                                Fun.protect
                                  ~finally:(fun () ->
                                    if Queue.length recent_closed = capacity
                                    then ignore (Queue.take recent_closed);
                                    Queue.add
                                      (`Assoc
                                         [
                                           ("id", `Int c.id);
                                           ( "write_idle_seconds",
                                             `Float (now () -. c.last_write) );
                                         ])
                                      recent_closed;
                                    Hashtbl.remove connections c.id;
                                    incr closed)
                                  transport.close));
                        },
                        string_of_int c.id ))
                    handler)
                (fun () ->
                  while true do
                    Eio.Time.Mono.sleep clock 0.25;
                    publish ()
                  done);
              publish ();
              print_endline (Yojson.Safe.to_string (snapshot ~gc:true ()));
              if
                !opened <> !closed || !unexpected <> 0 || !violations <> 0
                || Hashtbl.length queues <> 0
              then failwith "stress fixture cleanup")))
