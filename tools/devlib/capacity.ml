open Common

let attempts = 128
let rss_limit = 512 * 1024

let capacities text =
  let values = Endpoint_profile.concurrencies text in
  require
    (values <> []
    && List.for_all (fun n -> List.mem n [ 1; 16; 64 ]) values
    && List.length values = List.length (List.sort_uniq compare values))
    "Capacities must be distinct selections from 1,16,64";
  values

let check_snapshot ~capacity ~active row =
  let opened = int (field "opened" row)
  and closed = int (field "closed" row)
  and peak = int (field "peak_active" row) in
  require
    (active > 0 && active <= capacity && closed >= 0 && opened >= active
    && int (field "active" row) = active
    && peak >= active && peak <= capacity
    && opened - closed = active
    && field "unexpected_errors" row = `Int 0)
    "Capacity/connection ownership mismatch";
  require (int (field "rss_kib" row) <= rss_limit) "Sampled RSS exceeds 512 MiB"

let held_snapshot ~capacity app connection =
  let response = Framework.request ~connection app "GET" "/stats" in
  require (response.status = 200) "Missing held-connection statistics";
  let row =
    Load.process_resources app.Framework.child.pid
      (Yojson.Basic.from_string response.body)
  in
  check_snapshot ~capacity ~active:capacity row;
  row

let close_all sockets =
  let error = ref None in
  Array.iter
    (Option.iter (fun c ->
         try Network.close c
         with exn ->
           if !error = None then
             error := Some (exn, Printexc.get_raw_backtrace ())))
    sockets;
  Option.iter
    (fun (exn, trace) -> Printexc.raise_with_backtrace exn trace)
    !error

let live sockets =
  Array.to_list sockets |> List.filter_map Fun.id
  |> List.filter (fun c -> not c.Network.closed)

let peek connection =
  let byte = Bytes.create 1 in
  try
    let n = Unix.recv connection.Network.fd byte 0 1 [ Unix.MSG_PEEK ] in
    if n = 0 then Network.close connection;
    n > 0
  with
  | Unix.Unix_error (Unix.ECONNRESET, _, _) ->
      Network.close connection;
      false
  | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> false

let ready connections timeout =
  let readable, _, _ =
    Unix.select (List.map (fun c -> c.Network.fd) connections) [] [] timeout
  in
  List.filter (fun c -> List.mem c.Network.fd readable) connections

let cycle ~capacity app =
  let held = Array.make capacity None
  and queued = Array.make (attempts - capacity) None in
  let started = monotonic () in
  Fun.protect
    ~finally:(fun () ->
      Fun.protect
        ~finally:(fun () -> close_all queued)
        (fun () -> close_all held))
    (fun () ->
      Array.iteri
        (fun i _ ->
          let connection = Network.connect ~timeout:5. app.Framework.port in
          held.(i) <- Some connection;
          let response = Network.request connection "GET" "/health" in
          require
            (response.status = 200 && response.body = "ok\n")
            "Prefill health response")
        held;
      let control = Option.get held.(0) in
      let before = held_snapshot ~capacity app control in
      require
        (field "peak_active" before = `Int capacity)
        "Capacity was not reached";
      let results = Array.make (Array.length queued) None
      and threads = ref [] in
      (* Join every started worker before the outer scope retires its sockets,
         including partial thread creation and interruption of the coordinator. *)
      Fun.protect
        ~finally:(fun () -> List.iter Thread.join !threads)
        (fun () ->
          Array.iteri
            (fun i _ ->
              let worker () =
                results.(i) <-
                  Some
                    (try
                       let connection =
                         try Ok (Network.connect ~timeout:0.75 app.port) with
                         | Error message
                           when message = "Socket deadline exceeded" ->
                             Error "timeout"
                         | Unix.Unix_error (Unix.ECONNREFUSED, _, _) ->
                             Error "refused"
                         | Unix.Unix_error
                             ((Unix.ECONNRESET | Unix.ETIMEDOUT), _, _) ->
                             Error "reset-or-timeout"
                       in
                       match connection with
                       | Error classification -> Ok classification
                       | Ok connection ->
                           queued.(i) <- Some connection;
                           Network.send connection
                             "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
                           Ok "established"
                     with exn -> Error exn)
              in
              threads := Thread.create worker () :: !threads)
            queued);
      let results =
        Array.to_list results
        |> List.map (function
          | Some (Ok result) -> result
          | Some (Error exn) -> raise exn
          | None -> fail "Connection worker did not finish")
      in
      let established =
        List.filter (( = ) "established") results |> List.length
      in
      require (established > 0)
        "No queued TCP connection established; overload handoff untested";
      List.iter
        (fun c ->
          require
            (not (peek c))
            "Extra HTTP request served while every slot was held")
        (ready (live queued) 0.1);
      let pressure = held_snapshot ~capacity app control in
      require
        (field "opened" pressure = field "opened" before)
        "Additional transport admitted while every slot was held";
      Network.close (Option.get held.(capacity - 1));
      let released = monotonic () and deadline = monotonic () +. 5. in
      let rec replacement () =
        let pending = live queued in
        require
          (pending <> [] && monotonic () < deadline)
          "Released slot was not reused";
        match
          List.find_opt peek (ready pending (max 0. (deadline -. monotonic ())))
        with
        | Some c -> c
        | None -> replacement ()
      in
      let replacement = replacement () in
      let response = Network.response replacement "GET" in
      require
        (response.status = 200 && response.body = "ok\n")
        "Queued request failed after slot release";
      let handoff_seconds = monotonic () -. released in
      require (handoff_seconds <= 5.)
        "Queued response completed after handoff deadline";
      let after = held_snapshot ~capacity app replacement in
      require
        (int (field "opened" after) = int (field "opened" before) + 1
        && int (field "closed" after) = int (field "closed" before) + 1)
        "Released slot did not admit exactly one replacement";
      `Assoc
        [
          ("seconds", `Float (monotonic () -. started));
          ("attempted_connections", `Int attempts);
          ("prefilled_application_slots", `Int capacity);
          ("extra_established_tcp_connections", `Int established);
          ("extra_connection_results", strings results);
          ("handoff_seconds", `Float handoff_seconds);
          ("held", before);
          ("pressure", pressure);
          ("replacement", after);
        ])

let main args =
  let selected = capacities (option args "--capacities" "1,16,64") in
  let seconds = float_of_string (option args "--seconds" "0") in
  require
    (Float.is_finite seconds && seconds >= 0. && seconds <= 3600.)
    "Seconds per capacity must be in 0..3600 (zero runs one cycle)";
  ignore
    (Process.run
       ~env:(Build.measurement_environment ())
       (Build.command [ "build"; "examples/framework/server.exe" ]));
  let binary = Build.binary "examples/framework/server.exe" in
  let binary_digest = sha (read binary) in
  let digest = Build.source_hash () in
  let directory =
    temp_dir ~parent:(root / "_artifacts/framework") "capacity-"
  in
  let rows = ref [] in
  let report status extra =
    save
      (directory / "report.json")
      (`Assoc
         ([
            ("status", `String status);
            ("source_sha256", `String digest);
            ("binary_sha256", `String binary_digest);
            ( "os_arch",
              `String
                (String.trim (Process.output ~timeout:5. [ "uname"; "-srm" ]))
            );
            ("rss_limit_kib", `Int rss_limit);
            ( "client_runtime_overrides_inherited",
              `Bool
                (List.exists
                   (fun (key, _) -> Build.measurement_override key)
                   (environment ())) );
            ("compiler", `String Build.version);
            ("runtime", `String "eio");
            ("profile", `String "dev");
            ("seconds_requested_per_capacity", `Float seconds);
            ("attempted_connections_per_cycle", `Int attempts);
            ("capacities", `List (List.map (fun n -> `Int n) selected));
            ("results", `List !rows);
            ( "scope",
              `String
                "Keep-alive admission and TCP backlog pressure; not \
                 slow-body/stream or release acceptance" );
            ("public_release", `String "NOT_READY");
          ]
         @ extra))
  in
  report "RUNNING" [];
  try
    List.iter
      (fun capacity ->
        let dir = directory / Printf.sprintf "capacity-%d" capacity in
        mkdir dir;
        let env =
          set
            (Build.measurement_environment ())
            "HTTPKIT_MAX_CONNECTIONS" (string_of_int capacity)
        in
        Framework.with_app ~env ~binary ~directory:dir (fun app ->
            ignore (Endpoint_profile.counters ~capacity app);
            let idle () =
              Load.resources ~capacity app.port app.child.pid false
            in
            let baseline = idle () in
            let idle_rows = ref [ baseline ]
            and cycle_files = ref []
            and number = ref 0 in
            let started = monotonic () in
            while !number = 0 || monotonic () -. started < seconds do
              require
                (Build.source_hash () = digest)
                "Sources changed during capacity control";
              let result = cycle ~capacity app in
              let drained = idle () in
              check_snapshot ~capacity ~active:1 drained;
              require
                (int (field "descriptors" drained)
                <= int (field "descriptors" baseline) + 2)
                "Idle descriptors did not return within two of baseline";
              List.iter
                (fun key ->
                  let row = field key result in
                  require
                    (int (field "descriptors" row)
                    <= int (field "descriptors" baseline) + capacity + 2)
                    "Descriptors exceeded the admitted-connection budget")
                [ "held"; "pressure"; "replacement" ];
              idle_rows := !idle_rows @ [ drained ];
              Load.check_resources ~rss_limit_kib:rss_limit !idle_rows;
              incr number;
              let file = dir / Printf.sprintf "cycle-%06d.json" !number in
              save file (Benchmarks.setj "drained" drained result);
              cycle_files := !cycle_files @ [ file ];
              save (dir / "progress.json")
                (`Assoc
                   [
                     ("cycles", `Int !number);
                     ("seconds", `Float (monotonic () -. started));
                     ("files", strings !cycle_files);
                   ]);
              Printf.printf "Capacity %d: cycle %d passed\n%!" capacity !number
            done;
            Framework.close app;
            let final = Option.value ~default:`Null app.final in
            require
              (field "active" final = `Int 0
              && field "opened" final = field "closed" final
              && field "unexpected_errors" final = `Int 0)
              "Final connection cleanup failed";
            rows :=
              !rows
              @ [
                  `Assoc
                    [
                      ("capacity", `Int capacity);
                      ("cycles", `Int !number);
                      ("seconds", `Float (monotonic () -. started));
                      ("baseline", baseline);
                      ("cycle_files", strings !cycle_files);
                      ("final", final);
                    ];
                ];
            report "RUNNING" []))
      selected;
    require
      (Build.source_hash () = digest && sha (read binary) = binary_digest)
      "Sources or binary changed during capacity validation";
    report "PASS" [];
    Printf.printf "PASS capacity controls: %s\n%!" (directory / "report.json")
  with exn ->
    report "FAIL" [ ("error", `String (Printexc.to_string exn)) ];
    raise exn
