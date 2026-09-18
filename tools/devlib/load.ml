open Common
open Network

let buckets =
  [|
    0.1;
    0.2;
    0.5;
    1.;
    2.;
    5.;
    10.;
    20.;
    50.;
    100.;
    200.;
    500.;
    1000.;
    2000.;
    5000.;
    10000.;
  |]

let json_ints a = `List (Array.to_list a |> List.map (fun n -> `Int n))

let parallel count f =
  let stopped = Atomic.make false in
  let slots =
    Array.init count (fun i ->
        let result = ref None in
        let thread =
          Thread.create
            (fun () ->
              try result := Some (Ok (f stopped i))
              with exn ->
                Atomic.set stopped true;
                result := Some (Error exn))
            ()
        in
        (thread, result))
  in
  Array.iter (fun (t, _) -> Thread.join t) slots;
  Array.to_list slots
  |> List.map (fun (_, r) ->
      match !r with
      | Some (Ok value) -> value
      | Some (Error exn) -> raise exn
      | None -> fail "Worker did not complete")

let interruptible_sleep stopped duration =
  let deadline = monotonic () +. duration in
  while (not (Atomic.get stopped)) && monotonic () < deadline do
    sleep (min 0.05 (max 0. (deadline -. monotonic ())))
  done

let descriptors pid =
  let path = Printf.sprintf "/proc/%d/fd" pid in
  if Sys.file_exists path then Array.length (Sys.readdir path)
  else
    Process.output ~timeout:10. [ "lsof"; "-a"; "-p"; string_of_int pid; "-Ff" ]
    |> lines
    |> List.filter (fun s ->
        String.length s > 1
        && s.[0] = 'f'
        && String.for_all
             (fun c -> c >= '0' && c <= '9')
             (String.sub s 1 (String.length s - 1)))
    |> List.length

let process_resources pid row =
  `Assoc
    (assoc row
    @ [
        ( "rss_kib",
          `Int
            (int_of_string
               (String.trim
                  (Process.output ~timeout:5.
                     [ "ps"; "-o"; "rss="; "-p"; string_of_int pid ]))) );
        ("descriptors", `Int (descriptors pid));
      ])

let resources ?(capacity = 16) port pid persistent =
  let deadline = monotonic () +. 10. in
  let rec await () =
    let r = with_connection port (fun c -> request c "GET" "/stats") in
    require (r.status = 200) "Stats endpoint";
    let row = Yojson.Basic.from_string r.body in
    if int (field "active" row) = 1 + if persistent then 1 else 0 then row
    else (
      require (monotonic () < deadline) "Unclosed transports";
      sleep 0.02;
      await ())
  in
  let row = await () in
  require
    (field "unexpected_errors" row = `Int 0
    && int (field "peak_active" row) <= capacity
    && int (field "opened" row)
       = int (field "closed" row) + int (field "active" row))
    "Application ownership/admission errors";
  process_resources pid row

let check_resources ?(rss_limit_kib = 262144) rows =
  require (rss_limit_kib > 0) "Invalid RSS limit";
  require (rows <> []) "Missing resource observations";
  List.iter
    (fun r ->
      require
        (field "active" r = `Int 1 && field "unexpected_errors" r = `Int 0)
        "Cleanup or application errors")
    rows;
  let rec drop n xs =
    if n = 0 then xs else match xs with [] -> [] | _ :: xs -> drop (n - 1) xs
  in
  let warm = drop (min 2 (List.length rows - 1)) rows in
  let values key rows = List.map (fun r -> float (int (field key r))) rows in
  let range xs =
    List.fold_left max neg_infinity xs -. List.fold_left min infinity xs
  in
  require (range (values "descriptors" warm) <= 2.) "Descriptor growth";
  require
    (range (values "live_words" warm) <= 131072.)
    "Post-GC live heap growth exceeds 1 MiB";
  require
    (List.for_all (fun r -> int (field "rss_kib" r) <= rss_limit_kib) rows)
    (Printf.sprintf "RSS exceeds %d KiB" rss_limit_kib);
  if List.length warm >= 8 then
    let n = max 2 Stdlib.(List.length warm / 4) in
    let values = Array.of_list (values "rss_kib" warm) in
    let first = Array.sub values 0 n |> Array.to_list
    and last = Array.sub values (Array.length values - n) n |> Array.to_list in
    require
      (Benchmarks.median last -. Benchmarks.median first <= 32768.)
      "Post-warmup RSS growth exceeds 32 MiB"

let reset port path partial =
  with_connection port (fun c ->
      send c
        (if partial then
           "POST /upload HTTP/1.1\r\n\
            Host: x\r\n\
            Content-Length: 1048576\r\n\
            \r\n\
            x"
         else "GET " ^ path ^ " HTTP/1.1\r\nHost: x\r\n\r\n");
      if not partial then
        require
          (starts ~prefix:"HTTP/1.1 200" (recv c 64))
          "Reset stream did not start";
      Unix.setsockopt_optint c.fd Unix.SO_LINGER (Some 0))

let framework_operation app database c _rng mode =
  let req ?body ?headers meth path =
    Framework.request ?body ?headers ~connection:c app meth path
  in
  if mode = 1 && database then (
    let r = req "GET" "/db" in
    require (r.status = 200 && r.body = "1") "Database result";
    ("database", 1))
  else
    match mode with
    | 0 | 1 ->
        let r = req "GET" "/health" in
        require (r.status = 200 && r.body = "ok\n") "Health bytes";
        ("health", 3)
    | 2 ->
        let body = "{\"message\":\"" ^ String.make 4096 'x' ^ "\"}" in
        let r =
          req ~body
            ~headers:[ ("Content-Type", "application/json") ]
            "POST" "/json"
        in
        require (r.status = 200 && r.body = body) "JSON bytes";
        ("json", 2 * String.length body)
    | 3 ->
        let body =
          "--x\r\n\
           Content-Disposition: form-data; name=\"file\"; \
           filename=\"test.bin\"\r\n\
           \r\n" ^ String.make 16384 'x' ^ "\r\n--x--\r\n"
        in
        let r =
          req ~body
            ~headers:[ ("Content-Type", "multipart/form-data; boundary=x") ]
            "POST" "/upload"
        in
        require (r.status = 200 && r.body = "16384") "Multipart bytes";
        ("multipart", String.length body)
    | 4 | 5 ->
        let size = stream ~slow:(mode = 5) c "/stream" 1048576 in
        ((if mode = 5 then "slow-stream" else "stream"), size)
    | 6 ->
        let r =
          req
            ~headers:[ ("Authorization", "Bearer synthetic-test-token") ]
            "POST" "/login"
        in
        require (r.status = 200) "Login";
        let cookie =
          List.hd (String.split_on_char ';' (header "set-cookie" r))
        in
        let r = req ~headers:[ ("Cookie", cookie) ] "GET" "/session" in
        require (r.status = 200) "Session";
        let token = string (field "csrf" (Yojson.Basic.from_string r.body)) in
        let status =
          (req
             ~headers:
               [
                 ("Cookie", cookie);
                 ("Origin", "https://app.example");
                 ("X-CSRF-Token", token);
               ]
             "POST" "/logout")
            .status
        in
        require (status = 200) "Logout";
        ("session-cycle", String.length r.body)
    | 7 ->
        let r = req "GET" "/events" in
        require
          (r.status = 200
          && List.length (Str.split (Str.regexp_string "data: event ") r.body)
             = 4)
          "SSE";
        ("sse", String.length r.body)
    | 8 ->
        reset app.port "/stream" false;
        ("reset-stream", 0)
    | _ ->
        with_connection app.port (fun c ->
            send c
              ("GET /ws HTTP/1.1\r\n\
                Host: localhost\r\n\
                Connection: Upgrade\r\n\
                Upgrade: websocket\r\n\
                Sec-WebSocket-Version: 13\r\n\
                Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\n\
                Origin: https://app.example\r\n\
                \r\n" ^ Framework.frame 1 "hello");
            require (starts ~prefix:"HTTP/1.1 101" (head c)) "WebSocket upgrade";
            require (Framework.recv_frame c = (1, "hello")) "WebSocket echo";
            send c (Framework.frame 8 "");
            require (Framework.recv_frame c = (8, "")) "WebSocket close");
        ("websocket", 5)

let epoch ?diagnostics ~port ~seconds ~concurrency ~rate ~seed ~modes operation
    =
  let started = monotonic () in
  let deadline = started +. seconds in
  let rows =
    Load_trace.with_workers diagnostics concurrency (fun traces ->
        parallel concurrency (fun stopped index ->
            let trace = traces.(index) in
            try
              let rng = Random.State.make [| seed + index |]
              and counts = Hashtbl.create 16
              and hist = Hashtbl.create 16
              and transferred = ref 0
              and read_calls = ref 0 in
              with_connection ?trace port (fun c ->
                  while (not (Atomic.get stopped)) && monotonic () < deadline do
                    let start = monotonic () in
                    let name, size =
                      operation c rng (Random.State.int rng modes)
                    in
                    let elapsed = monotonic () -. start in
                    let bucket =
                      Array.find_index
                        (fun upper -> elapsed *. 1000. <= upper)
                        buckets
                    in
                    let bucket =
                      match bucket with
                      | Some n -> n
                      | None -> fail "Operation exceeded ten seconds: %s" name
                    in
                    Hashtbl.replace counts name
                      (1
                      + Option.value ~default:0 (Hashtbl.find_opt counts name));
                    let bins =
                      match Hashtbl.find_opt hist name with
                      | Some bins -> bins
                      | None ->
                          let bins = Array.make (Array.length buckets) 0 in
                          Hashtbl.add hist name bins;
                          bins
                    in
                    bins.(bucket) <- bins.(bucket) + 1;
                    transferred := !transferred + size;
                    Load_trace.completed trace;
                    if rate > 0. then
                      interruptible_sleep stopped
                        (max 0. ((float concurrency /. rate) -. elapsed))
                  done;
                  read_calls := c.read_calls);
              Load_trace.phase trace "finished";
              (counts, hist, !transferred, !read_calls)
            with exn ->
              Load_trace.phase trace "failed";
              raise exn))
  in
  let counts = Hashtbl.create 16
  and hist = Hashtbl.create 16
  and transferred = ref 0
  and read_calls = ref 0 in
  List.iter
    (fun (cs, hs, n, reads) ->
      read_calls := !read_calls + reads;
      transferred := !transferred + n;
      Hashtbl.iter
        (fun k v ->
          Hashtbl.replace counts k
            (v + Option.value ~default:0 (Hashtbl.find_opt counts k)))
        cs;
      Hashtbl.iter
        (fun k bins ->
          let dst =
            match Hashtbl.find_opt hist k with
            | Some a -> a
            | None ->
                let a = Array.make (Array.length buckets) 0 in
                Hashtbl.add hist k a;
                a
          in
          Array.iteri (fun i n -> dst.(i) <- dst.(i) + n) bins)
        hs)
    rows;
  let operations = Hashtbl.fold (fun _ v sum -> v + sum) counts 0
  and elapsed = monotonic () -. started in
  require (operations > 0) "Empty load epoch";
  require
    (rate = 0. || seconds < 30. || float operations >= seconds *. rate *. 0.25)
    "Insufficient sustained activity";
  let sorted h f =
    Hashtbl.to_seq h |> List.of_seq |> List.sort compare
    |> List.map (fun (k, v) -> (k, f v))
  in
  let total = Array.make (Array.length buckets) 0 in
  Hashtbl.iter
    (fun _ bins -> Array.iteri (fun i n -> total.(i) <- total.(i) + n) bins)
    hist;
  let percentile p =
    let sum = ref 0 in
    let i = ref 0 in
    while
      !i < Array.length buckets - 1
      && float (!sum + total.(!i)) < ceil (float operations *. p)
    do
      sum := !sum + total.(!i);
      incr i
    done;
    `Float buckets.(!i)
  in
  `Assoc
    [
      ("seconds", `Float elapsed);
      ("operations", `Int operations);
      ("operations_per_second", `Float (float operations /. elapsed));
      ("concurrency", `Int concurrency);
      ( "worker_operations",
        `List
          (List.map
             (fun (counts, _, _, _) ->
               `Int (Hashtbl.fold (fun _ count total -> count + total) counts 0))
             rows) );
      ("offered_operations_per_second", if rate = 0. then `Null else `Float rate);
      ("counts", `Assoc (sorted counts (fun n -> `Int n)));
      ("payload_bytes", `Int !transferred);
      ("persistent_client_read_calls", `Int !read_calls);
      ( "persistent_client_read_calls_per_operation",
        `Float (float !read_calls /. float operations) );
      ( "latency_upper_ms",
        `List (Array.to_list buckets |> List.map (fun n -> `Float n)) );
      ( "latency_bucket_upper_ms",
        `List (Array.to_list buckets |> List.map (fun n -> `Float n)) );
      ("latency_counts", json_ints total);
      ("latency_counts_by_workload", `Assoc (sorted hist json_ints));
      ("p50_upper_ms", percentile 0.5);
      ("p95_upper_ms", percentile 0.95);
      ("p99_upper_ms", percentile 0.99);
    ]

let graceful app =
  with_connection app.Framework.port (fun partial ->
      with_connection app.port (fun c ->
          send partial
            "POST /json HTTP/1.1\r\n\
             Host: localhost\r\n\
             Content-Type: application/json\r\n\
             Content-Length: 100\r\n\
             \r\n\
             {";
          let started = monotonic () in
          ignore
            (stream ~slow:true
               ~after_first:(fun () -> Process.signal app.child Sys.sigterm)
               c "/stream" 1048576);
          Framework.close app;
          let final = Option.value ~default:`Null app.final in
          require
            (field "active" final = `Int 0
            && field "opened" final = field "closed" final
            && field "unexpected_errors" final = `Int 0)
            "Shutdown accounting";
          `Assoc
            [ ("seconds", `Float (monotonic () -. started)); ("final", final) ]))

let with_persistent port f =
  let stopped = Atomic.make false
  and ready = Atomic.make false
  and error = ref None
  and requests = Atomic.make 0 in
  let thread =
    Thread.create
      (fun () ->
        try
          with_connection port (fun c ->
              while not (Atomic.get stopped) do
                let r = request c "GET" "/health" in
                require
                  (r.status = 200 && r.body = "ok\n")
                  "Persistent response";
                Atomic.incr requests;
                Atomic.set ready true;
                interruptible_sleep stopped 5.
              done)
        with exn ->
          error := Some exn;
          Atomic.set ready true)
      ()
  in
  let close () =
    Atomic.set stopped true;
    Thread.join thread;
    Option.iter raise !error
  in
  Fun.protect ~finally:close (fun () ->
      let deadline = monotonic () +. 15. in
      while not (Atomic.get ready) do
        require (monotonic () < deadline) "Persistent startup timeout";
        sleep 0.01
      done;
      Option.iter raise !error;
      f (fun () -> Option.iter raise !error) requests)

let main args =
  let mode = option args "--mode" "smoke"
  and database = option args "--database" "none" in
  require
    (List.mem mode [ "smoke"; "profile"; "canary"; "soak" ]
    && List.mem database [ "none"; "sqlite"; "postgresql" ])
    "Invalid load mode/database";
  let seconds =
    float_of_string
      (option args "--seconds"
         (match mode with
         | "smoke" -> "3"
         | "profile" -> "10"
         | "canary" -> "1800"
         | _ -> "7200"))
  in
  require
    (Float.is_finite seconds && seconds > 0.)
    "Positive finite duration required";
  let binary = option args "--binary" "" in
  if binary = "" then Build.call [ "build"; "examples/framework/server.exe" ];
  let binary =
    if binary = "" then Build.binary "examples/framework/server.exe"
    else absolute binary
  in
  let digest = Build.source_hash ()
  and directory =
    temp_dir ~parent:(root / "_artifacts/framework") (mode ^ "-")
  in
  let report =
    ref
      (`Assoc
         [
           ("status", `String "RUNNING");
           ("mode", `String mode);
           ("database", `String database);
           ("seconds_requested", `Float seconds);
           ("source_sha256", `String digest);
           ("binary_sha256", `String (sha (read binary)));
           ("epochs", `List []);
           ("observations", `List []);
         ])
  in
  let put key value = report := Benchmarks.setj key value !report in
  let append key value =
    put key (`List (list (field key !report) @ [ value ]))
  in
  let save_report () = save (directory / "report.json") !report in
  save_report ();
  try
    let run database_uri =
      Framework.with_app ?database_uri ~binary ~directory (fun app ->
          Framework.exercise app;
          let long = List.mem mode [ "canary"; "soak" ] in
          let workload check requests =
            append "observations" (resources app.port app.child.pid long);
            save_report ();
            let durations =
              if mode = "profile" then
                List.map (fun c -> (seconds, c)) [ 1; 4; 8 ]
              else
                let rec make remaining =
                  if remaining <= 0. then []
                  else (min 60. remaining, 4) :: make (remaining -. 60.)
                in
                make seconds
            in
            List.iteri
              (fun i (duration, concurrency) ->
                require
                  (Build.source_hash () = digest)
                  "Sources changed during load";
                append "epochs"
                  (epoch ~port:app.port ~seconds:duration ~concurrency
                     ~rate:(if long then 20. else 0.)
                     ~seed:(912 + (i * 100))
                     ~modes:10
                     (framework_operation app (database_uri <> None)));
                append "observations" (resources app.port app.child.pid long);
                check_resources
                  (List.map
                     (fun row ->
                       Benchmarks.setj "active"
                         (`Int (int (field "active" row) - if long then 1 else 0))
                         row)
                     (list (field "observations" !report)));
                check ();
                save_report ();
                Printf.printf "Completed load epoch %d/%d\n%!" (i + 1)
                  (List.length durations))
              durations;
            if long then
              put "persistent_connection_requests" (`Int (Atomic.get requests))
          in
          if long then with_persistent app.port workload
          else workload (fun () -> ()) (Atomic.make 0);
          put "shutdown" (graceful app))
    in
    (match database with
    | "none" -> run None
    | "sqlite" -> run (Some ("sqlite3:" ^ (directory / "load.sqlite")))
    | _ ->
        Databases.with_postgres (directory / "postgres") (fun uri ->
            run (Some uri)));
    require
      (Build.source_hash () = digest)
      "Sources changed during final checks";
    put "status" (`String "PASS");
    save_report ();
    save (root / "_artifacts/framework" / (mode ^ ".json")) !report;
    Printf.printf "PASS framework %s (%s): %s\n%!" mode database
      (directory / "report.json")
  with exn ->
    put "status" (`String "FAIL");
    put "error" (`String (Printexc.to_string exn));
    save_report ();
    raise exn
