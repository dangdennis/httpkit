open Common
open Network

let download = 2097152
let limit = 1048576

let request ?(body = "") ?(chunked = false) ?(slow = false) ?connection port
    meth path =
  let action c =
    if path = "/download" && meth = "GET" then
      let size = stream ~slow c path download in
      (200, "", size)
    else
      let r = Network.request ~body ~chunked c meth path in
      require (header "x-example" r = "personal-eio") "Middleware missing";
      require (String.length r.body <= 4096) "Unexpected large response";
      (r.status, r.body, String.length r.body)
  in
  match connection with
  | Some c -> action c
  | None -> with_connection port action

let balanced port =
  let deadline = monotonic () +. 10. in
  let rec loop () =
    let status, payload, _ = request port "GET" "/stats" in
    require (status = 200) "Stats status";
    let row = Yojson.Basic.from_string payload in
    if field "active" row = `Int 1 then (
      require
        (int (field "opened" row) = int (field "closed" row) + 1
        && field "unexpected_errors" row = `Int 0
        && int (field "peak_active" row) <= 16)
        "Ownership counts";
      row)
    else (
      require (monotonic () < deadline) "Connections did not clean up";
      sleep 0.02;
      loop ())
  in
  loop ()

let raw port wire =
  with_connection port (fun c ->
      (try send c wire
       with Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _) -> ());
      (try Unix.shutdown c.fd Unix.SHUTDOWN_SEND with Unix.Unix_error _ -> ());
      let out = Buffer.create 1024 in
      let rec loop () =
        let data = recv c 4096 in
        if data <> "" then (
          Buffer.add_string out data;
          require (Buffer.length out <= 8192) "Unexpected raw output";
          loop ())
      in
      loop ();
      Buffer.contents out)

let checksum body =
  String.fold_left (fun n c -> (n + Char.code c) mod 65536) 0 body

let adversarial port =
  let cases = ref 0 in
  List.iter
    (fun (meth, path, status) ->
      let actual, _, _ = request port meth path in
      require (actual = status) "Route outcome";
      incr cases)
    [
      ("GET", "/health", 200);
      ("GET", "/missing", 404);
      ("PUT", "/health", 405);
      ("HEAD", "/health", 405);
    ];
  let body = String.init limit (fun i -> Char.chr (i mod 256)) in
  List.iter
    (fun chunked ->
      let status, payload, _ = request ~body ~chunked port "POST" "/upload" in
      require
        (status = 200
        && payload
           = Printf.sprintf "%d %d\n" (String.length body) (checksum body))
        "Upload boundary";
      incr cases)
    [ false; true ];
  let head = "POST /upload HTTP/1.1\r\nHost: x\r\n"
  and marker = "GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" in
  List.iter
    (fun (fields, payload) ->
      let before = int (field "requests" (balanced port)) in
      let out = raw port (head ^ fields ^ "\r\n" ^ payload ^ marker) in
      require
        ((not (contains out "ok\n")) && not (contains out "200 "))
        "Ambiguous input answered";
      let after = int (field "requests" (balanced port)) in
      require (after - before <= 2) "Marker dispatched";
      incr cases)
    [
      ("Content-Length: 1\r\nTransfer-Encoding: chunked\r\n", "0\r\n\r\n");
      ("Content-Length: 0\r\nContent-Length: 1\r\n", "x");
      ("Content-Length: 1048577\r\n", "");
      ("Transfer-Encoding: chunked\r\n", "wat\r\n");
    ];
  let excess = String.make (limit + 1) 'x' in
  List.iter
    (fun wire ->
      require (not (contains (raw port wire) "200 ")) "Upload quota bypassed";
      incr cases)
    [
      head ^ "Content-Length: 1048577\r\n\r\n" ^ excess;
      head ^ "Transfer-Encoding: chunked\r\n\r\n100001\r\n" ^ excess
      ^ "\r\n0\r\n\r\n";
    ];
  let out =
    raw port
      "POST /missing HTTP/1.1\r\n\
       Host: x\r\n\
       Expect: 100-continue\r\n\
       Content-Length: 9\r\n\
       \r\n"
  in
  require (contains out "404 " && not (contains out "100 ")) "Early rejection";
  incr cases;
  let out = raw port marker in
  require
    (ends ~suffix:"ok\n" out
    && List.length (Str.split (Str.regexp_string "HTTP/1.1") out) = 1)
    "Half close";
  incr cases;
  List.iter
    (fun wire ->
      require
        (not (contains (raw port wire) "200 "))
        "Truncated upload accepted";
      incr cases)
    [
      head ^ "Content-Length: 5\r\n\r\nx";
      head ^ "Transfer-Encoding: chunked\r\n\r\n5\r\nx";
    ];
  ignore (balanced port);
  !cases

let operation port c rng mode =
  if mode = 8 || mode = 9 then (
    Load.reset port "/download" (mode = 8);
    ((if mode = 9 then "reset-download" else "reset-upload"), 0))
  else if mode = 5 || mode = 6 then
    let _, _, size =
      request ~connection:c ~slow:(mode = 6) port "GET" "/download"
    in
    ((if mode = 6 then "slow-download" else "download"), size)
  else if List.mem mode [ 2; 3; 4; 10 ] then (
    let sizes = [| 0; 17; 4096; 262144 |] in
    let size = sizes.(Random.State.int rng 4) in
    let body = String.make size (Char.chr (Random.State.int rng 256)) in
    let status, payload =
      if mode = 10 then (
        start_request
          ~headers:[ ("transfer-encoding", "chunked") ]
          c "POST" "/upload";
        let rec send_chunks off =
          if off < size then (
            let n = min 8192 (size - off) in
            sleep 0.001;
            send c (Printf.sprintf "%x\r\n%s\r\n" n (String.sub body off n));
            send_chunks (off + n))
        in
        send_chunks 0;
        send c "0\r\n\r\n";
        let r = response c "POST" in
        (r.status, r.body))
      else
        let status, payload, _ =
          request ~body ~chunked:(mode = 4) ~connection:c port "POST" "/upload"
        in
        (status, payload)
    in
    require
      (status = 200 && payload = Printf.sprintf "%d %d\n" size (checksum body))
      "Upload corruption";
    ( (if mode = 10 then "slow-upload"
       else if mode = 4 then "chunked-upload"
       else "fixed-upload"),
      size ))
  else
    let status, payload, _ = request ~connection:c port "GET" "/health" in
    require (status = 200 && payload = "ok\n") "Health corruption";
    ("health", 0)

let graceful port child log stop_fd =
  with_connection port (fun partial ->
      with_connection port (fun c ->
          send partial
            "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nx";
          let started = monotonic () in
          ignore
            (stream ~slow:true
               ~after_first:(fun () ->
                 ignore (Unix.write_substring stop_fd "stop\n" 0 5))
               c "/download" download);
          let status = Process.wait child (monotonic () +. 15.) in
          require (Process.status_code status = 0) "Personal shutdown failed";
          let final =
            Yojson.Basic.from_string (List.hd (List.rev (lines (read log))))
          in
          require
            (field "active" final = `Int 0
            && field "opened" final = field "closed" final
            && field "unexpected_errors" final = `Int 0)
            "Shutdown leaked";
          `Assoc
            [ ("seconds", `Float (monotonic () -. started)); ("final", final) ]))

let main args =
  let mode = option args "--mode" "smoke" in
  require (List.mem mode [ "smoke"; "profile"; "soak" ]) "Invalid personal mode";
  let seconds =
    float_of_string
      (option args "--seconds"
         (if mode = "smoke" then "3"
          else if mode = "profile" then "10"
          else "7200"))
  and epoch_seconds = float_of_string (option args "--epoch-seconds" "60")
  and rate = float_of_string (option args "--rate" "20") in
  require
    (List.for_all
       (fun f -> Float.is_finite f && f > 0.)
       [ seconds; epoch_seconds; rate ])
    "Positive finite duration/rate required";
  let digest = Build.source_hash () and binary = option args "--binary" "" in
  if binary = "" then Build.call [ "build"; "examples/personal/eio_server.exe" ];
  let binary =
    if binary = "" then Build.binary "examples/personal/eio_server.exe"
    else absolute binary
  in
  let directory =
    temp_dir ~parent:(root / "_artifacts/personal") (mode ^ "-")
  in
  let report =
    ref
      (`Assoc
         [
           ("status", `String "RUNNING");
           ("source_sha256", `String digest);
           ("mode", `String mode);
           ("seconds_requested", `Float seconds);
           ("directory", `String directory);
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
    let input, output = Unix.pipe ~cloexec:true () in
    Fun.protect
      ~finally:(fun () ->
        Unix.close input;
        Unix.close output)
      (fun () ->
        with_server ~stdin:input ~directory ~prefix:"" [ binary ]
          (fun value child log ->
            let port = int_of_string value in
            put "adversarial_cases" (`Int (adversarial port));
            append "observations" (Load.resources port child.pid false);
            List.iter
              (fun concurrency ->
                let remaining = ref seconds in
                while !remaining > 0. do
                  let duration = min epoch_seconds !remaining in
                  append "epochs"
                    (Load.epoch ~port ~seconds:duration ~concurrency
                       ~rate:(if mode = "profile" then 0. else rate)
                       ~seed:
                         (42
                         + (100 * List.length (list (field "epochs" !report))))
                       ~modes:11 (operation port));
                  append "observations" (Load.resources port child.pid false);
                  Load.check_resources (list (field "observations" !report));
                  require
                    (Build.source_hash () = digest)
                    "Sources changed during personal workload";
                  save_report ();
                  remaining := !remaining -. duration;
                  Printf.printf "Personal %s: %.1fs remaining\n%!" mode
                    !remaining
                done)
              (if mode = "profile" then [ 1; 4; 8 ] else [ 4 ]);
            put "shutdown" (graceful port child log output)));
    require
      (Build.source_hash () = digest)
      "Sources changed during final personal checks";
    put "status" (`String "PASS");
    put "timing_verdict" (`String "ADVISORY_LOCAL_HOST");
    put "limitations"
      (strings
         [
           "Closed-loop OCaml client; latency buckets include intentional slow \
            reads and resets.";
           "Resource observations are quiescent between epochs; transient RSS \
            is not sampled.";
           "Personal-use evidence does not satisfy public-release policy.";
         ]);
    save_report ();
    save (root / "_artifacts" / ("personal-" ^ mode ^ ".json")) !report;
    Printf.printf "PASS personal %s: %s\n%!" mode (directory / "report.json")
  with exn ->
    put "status" (`String "FAIL");
    put "error" (`String (Printexc.to_string exn));
    save_report ();
    raise exn
