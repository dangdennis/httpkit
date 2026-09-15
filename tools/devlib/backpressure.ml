open Common

let stream_bytes = 8 * 1024 * 1024
let scenarios = [ "resume"; "reset"; "timeout"; "shutdown" ]

let select value =
  let xs = String.split_on_char ',' value in
  require
    (xs <> []
    && List.for_all (fun x -> List.mem x scenarios) xs
    && List.length xs = List.length (List.sort_uniq compare xs))
    "Invalid backpressure scenarios";
  List.filter (( <> ) "shutdown") xs
  @ if List.mem "shutdown" xs then [ "shutdown" ] else []

let count key row =
  match List.assoc_opt key (assoc (field "failures" row)) with
  | None -> 0
  | Some n -> int n

let check ~capacity row =
  let active = int (field "active" row) in
  require
    (active >= 0 && active <= capacity
    && int (field "opened" row) - int (field "closed" row) = active
    && int (field "peak_active" row) <= capacity
    && field "unexpected_errors" row = `Int 0
    && field "violations" row = `Int 0
    && count "unexpected" row = 0
    && int (field "queue_peak" row) <= 32768
    && List.length (list (field "connections" row)) = active
    && List.length (list (field "queues" row)) <= capacity)
    "Stress fixture ownership/queue failure"

let blocked ~capacity row =
  field "active" row = `Int capacity
  && List.length (list (field "queues" row)) = capacity
  && List.for_all
       (fun n -> int n > 0 && int n <= 32768)
       (list (field "queues" row))
  && List.for_all
       (fun c ->
         field "producing" c = `Bool true
         && field "sending" c = `Bool true
         && int (field "produced" c) > 0
         && int (field "produced" c) < stream_bytes)
       (list (field "connections" row))

let progress row =
  list (field "connections" row)
  |> List.map (fun c ->
      (int (field "id" c), int (field "written" c), int (field "produced" c)))
  |> List.sort compare

let check_write_timeout ~capacity before row =
  require
    (count "write" row - count "write" before = capacity)
    "Blocked output did not fail with write timeout";
  let timings = list (field "closed_connections" row) in
  let ids rows =
    List.map (fun c -> int (field "id" c)) rows |> List.sort compare
  in
  require
    (ids timings = ids (list (field "connections" before)))
    "Missing write-timeout closure timings";
  List.iter
    (fun c ->
      let idle = number (field "write_idle_seconds" c) in
      require
        (idle >= 28. && idle <= 35.)
        "Write idle timeout outside configured tolerance")
    timings

let state ~capacity ~snapshot ~record () =
  let row = json snapshot in
  save record row;
  check ~capacity row;
  row

let wait ~timeout read condition =
  let deadline = monotonic () +. timeout in
  let rec loop () =
    let row = read () in
    require (monotonic () <= deadline) "Stress state deadline exceeded";
    if condition row then row
    else (
      sleep 0.05;
      loop ())
  in
  loop ()

let stable ~capacity first second =
  blocked ~capacity first && blocked ~capacity second
  && progress first = progress second
  && number (field "snapshot_seconds" second)
     -. number (field "snapshot_seconds" first)
     >= 1.

let wait_blocked ~capacity read =
  let first = ref None in
  wait ~timeout:15. read (fun row ->
      if not (blocked ~capacity row) then (
        first := None;
        false)
      else
        match !first with
        | Some previous when stable ~capacity previous row -> true
        | Some previous when progress previous = progress row -> false
        | _ ->
            first := Some row;
            false)

let resources ~capacity ~baseline app row =
  let row = Load.process_resources app.Framework.child.pid row in
  require
    (int (field "rss_kib" row) <= Capacity.rss_limit
    && int (field "descriptors" row)
       <= int (field "descriptors" baseline) + capacity + 2)
    "Blocked producer process-resource limit";
  row

let parallel sockets f =
  let threads = ref [] and results = Array.make (Array.length sockets) None in
  Fun.protect
    ~finally:(fun () -> List.iter Thread.join !threads)
    (fun () ->
      Array.iteri
        (fun i c ->
          let worker () =
            results.(i) <-
              Some (try Ok (f (Option.get c)) with exn -> Error exn)
          in
          threads := Thread.create worker () :: !threads)
        sockets);
  Array.iter
    (function
      | Some (Ok ()) -> ()
      | Some (Error e) -> raise e
      | None -> fail "Stress worker missing result")
    results

(* The client checks chunks as they arrive and never retains the whole stream. *)
let consume c =
  Unix.setsockopt_int c.Network.fd Unix.SO_RCVBUF (1024 * 1024);
  let deadline = monotonic () +. 45. in
  let head = Network.head c in
  let response = Network.reference ~meth:"HEAD" head in
  require
    (response.status = 200
    && Network.header "transfer-encoding" response = "chunked"
    && Network.header "content-length" response = "")
    "Stream response head";
  let total = ref 0 in
  let rec loop () =
    require (monotonic () < deadline) "Resumed stream deadline";
    let n = int_of_string ("0x" ^ String.trim (Network.line c)) in
    require
      (n >= 0 && n <= 8192 && !total + n <= stream_bytes)
      "Stream chunk bound";
    if n = 0 then require (Network.line c = "\r\n") "Stream final terminator"
    else
      let data = Network.exact c n in
      require
        (String.for_all (( = ) 'x') data && Network.exact c 2 = "\r\n")
        "Stream bytes";
      total := !total + n;
      loop ()
  in
  loop ();
  require
    (!total = stream_bytes && monotonic () <= deadline)
    "Incomplete or late resumed stream";
  let r = Network.request c "GET" "/health" in
  require (r.status = 200 && r.body = "ok\n") "Resumed stream connection reuse"

let run ~capacity ~scenario ~snapshot ~directory app baseline =
  let sockets = Array.make capacity None in
  let read =
    state ~capacity ~snapshot ~record:(directory / (scenario ^ "-latest.json"))
  in
  Fun.protect
    ~finally:(fun () -> Capacity.close_all sockets)
    (fun () ->
      Array.iteri
        (fun i _ ->
          let c = Network.connect ~receive_buffer:16384 app.Framework.port in
          sockets.(i) <- Some c;
          let r = Network.request c "GET" "/health" in
          require (r.status = 200 && r.body = "ok\n") "Backpressure prefill")
        sockets;
      let before =
        Capacity.held_snapshot ~capacity app (Option.get sockets.(0))
      in
      Array.iter
        (Option.iter (fun c ->
             Network.send c "GET /blocked HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        sockets;
      let started = monotonic () in
      let second = wait_blocked ~capacity read in
      let pressure = resources ~capacity ~baseline app second in
      save (directory / (scenario ^ "-blocked.json")) pressure;
      let after =
        match scenario with
        | "resume" ->
            parallel sockets consume;
            let row =
              wait ~timeout:5. read (fun row ->
                  int (field "producer_finished" row)
                  >= int (field "producer_finished" before) + capacity)
            in
            require
              (int (field "producer_finished" row)
               = int (field "producer_finished" before) + capacity
              && field "producer_failed" row = field "producer_failed" before)
              "Resumed producers did not finish";
            row
        | "reset" ->
            Array.iter
              (Option.iter (fun c ->
                   Unix.setsockopt_optint c.Network.fd Unix.SO_LINGER (Some 0)))
              sockets;
            Capacity.close_all sockets;
            wait ~timeout:5. read (fun row -> field "active" row = `Int 0)
        | "timeout" ->
            let row =
              wait
                ~timeout:(max 0. (55. -. (monotonic () -. started)))
                read
                (fun row -> field "active" row = `Int 0)
            in
            check_write_timeout ~capacity before row;
            row
        | "shutdown" ->
            Framework.close app;
            Option.get app.final
        | _ -> assert false
      in
      check ~capacity after;
      if scenario <> "resume" then
        require
          (field "producer_finished" after = field "producer_finished" before
          && int (field "producer_failed" after)
             = int (field "producer_failed" before) + capacity)
          "Blocked producers escaped cleanup";
      `Assoc
        [
          ("capacity", `Int capacity);
          ("scenario", `String scenario);
          ("seconds", `Float (monotonic () -. started));
          ("before", before);
          ("blocked", pressure);
          ("after", after);
        ])

let campaign ~kind ~scope ~run ~capacities ~selected () =
  ignore
    (Process.run
       ~env:(Build.measurement_environment ())
       (Build.command [ "build"; "test/stress/server.exe" ]));
  let binary = Build.binary "test/stress/server.exe" in
  let digest = Build.source_hash () and binary_digest = sha (read binary) in
  let directory =
    temp_dir ~parent:(root / "_artifacts/framework") (kind ^ "-")
  in
  let results = ref [] in
  let report status extra =
    save
      (directory / "report.json")
      (`Assoc
         ([
            ("status", `String status);
            ("source_sha256", `String digest);
            ("binary_sha256", `String binary_digest);
            ("compiler", `String Build.version);
            ("runtime", `String "eio");
            ("profile", `String "dev");
            ( "os_arch",
              `String (String.trim (Process.output [ "uname"; "-srm" ])) );
            ("capacities", `List (List.map (fun n -> `Int n) capacities));
            ("scenarios", strings selected);
            ("results", `List !results);
            ("public_release", `String "NOT_READY");
            ("scope", `String scope);
          ]
         @ extra))
  in
  report "RUNNING" [];
  try
    List.iter
      (fun capacity ->
        let dir = directory / Printf.sprintf "capacity-%d" capacity in
        mkdir dir;
        let snapshot = dir / "snapshot.json" in
        let env =
          Build.measurement_environment () |> fun e ->
          set e "HTTPKIT_MAX_CONNECTIONS" (string_of_int capacity) |> fun e ->
          set e "HTTPKIT_STRESS_SNAPSHOT" snapshot
        in
        Framework.with_app ~env ~binary ~directory:dir (fun app ->
            ignore (Endpoint_profile.counters ~capacity app);
            let baseline =
              Load.resources ~capacity app.port app.child.pid false
            in
            let idle_rows = ref [ baseline ] in
            List.iter
              (fun scenario ->
                require
                  (Build.source_hash () = digest)
                  "Source changed during backpressure test";
                let row =
                  run ~capacity ~scenario ~snapshot ~directory:dir app baseline
                in
                let row =
                  if app.closed then row
                  else
                    let idle =
                      Load.resources ~capacity app.port app.child.pid false
                    in
                    check ~capacity idle;
                    require
                      (int (field "descriptors" idle)
                      <= int (field "descriptors" baseline) + 2)
                      "Backpressure descriptor leak";
                    idle_rows := !idle_rows @ [ idle ];
                    Load.check_resources ~rss_limit_kib:Capacity.rss_limit
                      !idle_rows;
                    Benchmarks.setj "drained" idle row
                in
                save (dir / (scenario ^ ".json")) row;
                results := !results @ [ row ];
                report "RUNNING" [];
                Printf.printf "%s %d %s: PASS\n%!" kind capacity scenario)
              selected;
            Framework.close app;
            let final = Option.get app.final in
            check ~capacity final;
            require
              (field "active" final = `Int 0 && field "queues" final = `List [])
              "Backpressure final cleanup";
            save (dir / "final.json") final))
      capacities;
    require
      (Build.source_hash () = digest && sha (read binary) = binary_digest)
      "Source/binary changed during backpressure test";
    report "PASS" [];
    Printf.printf "PASS %s controls: %s\n%!" kind (directory / "report.json")
  with exn ->
    report "FAIL" [ ("error", `String (Printexc.to_string exn)) ];
    raise exn

let main args =
  let capacities = Capacity.capacities (option args "--capacities" "1,16,64")
  and selected =
    select (option args "--scenarios" (String.concat "," scenarios))
  in
  campaign ~kind:"backpressure"
    ~scope:
      "Observed blocked producers on real sockets; short functional control, \
       not sustained acceptance"
    ~run ~capacities ~selected ()
