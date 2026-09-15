open Common

let scenarios =
  [
    "ignore-fixed";
    "ignore-trailers";
    "ignore-malformed";
    "ignore-stalled";
    "consume-fixed";
    "consume-trailers";
    "consume-malformed";
  ]

let select value =
  let selected = String.split_on_char ',' value in
  require
    (selected <> []
    && List.for_all (fun s -> List.mem s scenarios) selected
    && List.length selected = List.length (List.sort_uniq compare selected))
    "Invalid unread-body scenarios";
  selected

let embedded = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"

let wire scenario =
  let consume = starts ~prefix:"consume-" scenario in
  let head =
    "POST "
    ^ (if consume then "/consume" else "/ignore")
    ^ " HTTP/1.1\r\nHost: localhost\r\n"
  in
  if ends ~suffix:"-stalled" scenario then
    head ^ "Content-Length: 65536\r\n\r\nx"
  else
    let body =
      if ends ~suffix:"-fixed" scenario then
        Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length embedded)
          embedded
      else if ends ~suffix:"-trailers" scenario then
        Printf.sprintf
          "Transfer-Encoding: chunked\r\n\
           Trailer: x-note\r\n\
           \r\n\
           %x\r\n\
           %s\r\n\
           0\r\n\
           x-note: done\r\n\
           \r\n"
          (String.length embedded) embedded
      else "Transfer-Encoding: chunked\r\n\r\n1\r\nx!\r\n0\r\n\r\n"
    in
    head ^ body ^ embedded

let run ~capacity ~scenario ~snapshot ~directory app baseline =
  let sockets = Array.make capacity None in
  let read =
    Backpressure.state ~capacity ~snapshot
      ~record:(directory / (scenario ^ "-latest.json"))
  in
  Fun.protect
    ~finally:(fun () -> Capacity.close_all sockets)
    (fun () ->
      Array.iteri
        (fun i _ ->
          let c = Network.connect app.Framework.port in
          sockets.(i) <- Some c;
          let r = Network.request c "GET" "/health" in
          require (r.status = 200 && r.body = "ok\n") "Unread-body prefill")
        sockets;
      let before =
        Capacity.held_snapshot ~capacity app (Option.get sockets.(0))
      in
      let consume = starts ~prefix:"consume-" scenario
      and malformed = ends ~suffix:"-malformed" scenario in
      let reuse = consume && not malformed in
      let started = monotonic () in
      Array.iter (Option.iter (fun c -> Network.send c (wire scenario))) sockets;
      if not (consume && malformed) then
        Backpressure.parallel sockets (fun c ->
            let response = Network.response c "POST" in
            require
              (response.status = 200
              && response.body = if consume then embedded else "ignored\n")
              "Unread-body response bytes";
            if reuse then
              let second = Network.response c "GET" in
              require
                (second.status = 200 && second.body = "ok\n")
                "Consumed-body pipeline reuse");
      let expected_requests =
        int (field "requests" before) + (capacity * if reuse then 2 else 1)
      in
      let after =
        Backpressure.wait ~timeout:5. read (fun row ->
            if reuse then int (field "requests" row) >= expected_requests
            else
              int (field "requests" row) >= expected_requests
              && field "active" row = `Int 0)
      in
      require
        (int (field "requests" after) = expected_requests)
        "Unread bytes were dispatched as an additional request";
      if not reuse then (
        (* Check peer closure before the client cleanup runs, including buffered
           read-ahead where an incorrectly dispatched response could hide. *)
        Array.iter
          (Option.iter (fun c ->
               require
                 (Network.recv ~timeout:1. c 1 = "")
                 "Early response allowed unread-body reuse"))
          sockets;
        require
          (monotonic () -. started <= 5.)
          "Unread body was drained or timed out instead of promptly closed");
      if consume && malformed then
        require
          (Backpressure.count "protocol" after
           - Backpressure.count "protocol" before
          = capacity)
          "Consumed malformed framing was not rejected";
      let resources = Backpressure.resources ~capacity ~baseline app after in
      `Assoc
        [
          ("capacity", `Int capacity);
          ("scenario", `String scenario);
          ("seconds", `Float (monotonic () -. started));
          ("before", before);
          ("after", resources);
          ("requests_expected", `Int expected_requests);
          ("connection_reused", `Bool reuse);
        ])

let main args =
  let capacities = Capacity.capacities (option args "--capacities" "1,16,64")
  and selected =
    select (option args "--scenarios" (String.concat "," scenarios))
  in
  Backpressure.campaign ~kind:"unread-body"
    ~scope:
      "Early responses abort unread uploads; consumed bodies permit reuse. \
       Short real-socket control, not sustained acceptance."
    ~run ~capacities ~selected ()
