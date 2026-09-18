open Common

type connection = {
  trace : Load_trace.worker option;
  fd : Unix.file_descr;
  mutable closed : bool;
  mutable read_calls : int;
  buffer : bytes;
  mutable position : int;
  mutable available : int;
}

let of_fd ?trace fd =
  {
    trace;
    fd;
    closed = false;
    read_calls = 0;
    buffer = Bytes.create 8192;
    position = 0;
    available = 0;
  }

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let close c =
  if not c.closed then (
    Load_trace.phase c.trace "closing";
    c.closed <- true;
    Unix.close c.fd;
    Load_trace.phase c.trace "closed")

let ready fd write timeout =
  let r, w, _ =
    Unix.select
      (if write then [] else [ fd ])
      (if write then [ fd ] else [])
      [] timeout
  in
  require (r <> [] || w <> []) "Socket deadline exceeded"

let connect ?trace ?(timeout = 15.) ?receive_buffer port =
  Load_trace.phase trace "connecting";
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.set_nonblock fd;
  try
    Option.iter
      (fun n ->
        require (n > 0) "Invalid receive buffer";
        Unix.setsockopt_int fd Unix.SO_RCVBUF n)
      receive_buffer;
    (try Unix.connect fd (Unix.ADDR_INET (Unix.inet_addr_loopback, port))
     with Unix.Unix_error ((Unix.EINPROGRESS | Unix.EWOULDBLOCK), _, _) -> (
       ready fd true timeout;
       match Unix.getsockopt_error fd with
       | None -> ()
       | Some e -> raise (Unix.Unix_error (e, "connect", "loopback"))));
    Load_trace.phase trace "connected";
    of_fd ?trace fd
  with exn ->
    Unix.close fd;
    raise exn

let with_connection ?trace port f =
  let c = connect ?trace port in
  Fun.protect ~finally:(fun () -> close c) (fun () -> f c)

let send c s =
  let deadline = monotonic () +. 15. in
  let rec loop off =
    if off < String.length s then (
      Load_trace.phase c.trace "write-ready";
      ready c.fd true (max 0. (deadline -. monotonic ()));
      Load_trace.phase c.trace "writing";
      let n = Unix.write_substring c.fd s off (String.length s - off) in
      Load_trace.phase c.trace "processing";
      require (n > 0) "Socket write stopped";
      loop (off + n))
  in
  loop 0

let recv ?(timeout = 15.) c n =
  require (n >= 0 && not c.closed) "Invalid client read";
  if n = 0 then ""
  else (
    if c.position = c.available then (
      Load_trace.phase c.trace "read-ready";
      ready c.fd false timeout;
      Load_trace.phase c.trace "reading";
      c.position <- 0;
      c.available <- 0;
      c.read_calls <- c.read_calls + 1;
      c.available <-
        (try Unix.read c.fd c.buffer 0 (Bytes.length c.buffer)
         with Unix.Unix_error (Unix.ECONNRESET, _, _) -> 0);
      Load_trace.phase c.trace "processing");
    let count = min n (c.available - c.position) in
    let result = Bytes.sub_string c.buffer c.position count in
    c.position <- c.position + count;
    result)

let exact c n =
  require (n >= 0 && n <= 64 * 1024 * 1024) "Read size limit";
  let b = Buffer.create n in
  while Buffer.length b < n do
    let s = recv c (n - Buffer.length b) in
    require (s <> "") "Unexpected EOF";
    Buffer.add_string b s
  done;
  Buffer.contents b

let line c =
  let b = Buffer.create 80 in
  let rec loop () =
    require (Buffer.length b < 65536) "Header line limit";
    let s = exact c 1 in
    Buffer.add_string b s;
    if s = "\n" then Buffer.contents b else loop ()
  in
  loop ()

let head c =
  let b = Buffer.create 256 in
  let rec loop () =
    let s = line c in
    Buffer.add_string b s;
    require (Buffer.length b <= 262144) "Header limit";
    if s = "\r\n" then Buffer.contents b else loop ()
  in
  loop ()

let values name r =
  List.filter_map
    (fun (k, v) ->
      if String.lowercase_ascii k = String.lowercase_ascii name then Some v
      else None)
    r.headers

let header name r = match values name r with [] -> "" | x :: _ -> x

let reference ?(meth = "GET") wire =
  if meth = "HEAD" then
    match
      Angstrom.parse_string ~consume:All Httpaf.Httpaf_private.Parse.response
        wire
    with
    | Ok r ->
        {
          status = Httpaf.Status.to_code r.Httpaf.Response.status;
          headers = List.rev (Httpaf.Headers.to_list r.headers);
          body = "";
        }
    | Error e -> fail "Independent HEAD parser: %s" e
  else
    let result = ref None
    and finished = ref false
    and body = Buffer.create 128 in
    let request =
      Httpaf.Request.create
        ~headers:(Httpaf.Headers.of_list [ ("host", "localhost") ])
        (Httpaf.Method.of_string meth)
        "/"
    in
    let response_handler response reader =
      result :=
        Some
          ( Httpaf.Status.to_code response.Httpaf.Response.status,
            List.rev (Httpaf.Headers.to_list response.headers) );
      let rec schedule () =
        Httpaf.Body.schedule_read reader
          ~on_eof:(fun () -> finished := true)
          ~on_read:(fun b ~off ~len ->
            Buffer.add_string body (Bigstringaf.substring b ~off ~len);
            schedule ())
      in
      schedule ()
    in
    let writer, conn =
      Httpaf.Client_connection.request request
        ~error_handler:(fun _ ->
          fail "Independent http/af response parser rejected wire")
        ~response_handler
    in
    Httpaf.Body.close_writer writer;
    let b = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
    let consumed =
      Httpaf.Client_connection.read conn b ~off:0 ~len:(String.length wire)
    in
    if not !finished then
      ignore
        (Httpaf.Client_connection.read_eof conn b ~off:consumed
           ~len:(String.length wire - consumed));
    require !finished "Independent response parser did not complete";
    match !result with
    | Some (status, headers) -> { status; headers; body = Buffer.contents body }
    | None -> fail "Missing independent response head"

let response c meth =
  let wire = Buffer.create 1024 in
  let capture s =
    Buffer.add_string wire s;
    s
  in
  let h = capture (head c) in
  let ls = String.split_on_char '\n' h |> List.map String.trim in
  let status =
    match String.split_on_char ' ' (List.hd ls) with
    | _ :: s :: _ -> int_of_string s
    | _ -> fail "Invalid status"
  in
  let headers =
    List.tl ls
    |> List.filter_map (fun s ->
        match String.index_opt s ':' with
        | None -> None
        | Some i ->
            Some
              ( String.lowercase_ascii (String.sub s 0 i),
                String.trim (String.sub s (i + 1) (String.length s - i - 1)) ))
  in
  let provisional = { status; headers; body = "" } in
  (if meth <> "HEAD" && status <> 204 && status <> 304 && status >= 200 then
     if
       String.lowercase_ascii (header "transfer-encoding" provisional)
       = "chunked"
     then
       let rec chunks () =
         let h = capture (line c) in
         let size = List.hd (String.split_on_char ';' (String.trim h)) in
         let n = int_of_string ("0x" ^ size) in
         require
           (n >= 0
           && n <= 64 * 1024 * 1024
           && Buffer.length wire + n <= 64 * 1024 * 1024)
           "Chunked response bound";
         if n = 0 then ignore (capture (head c))
         else (
           ignore (capture (exact c n));
           require (capture (exact c 2) = "\r\n") "Chunk terminator";
           chunks ())
       in
       chunks ()
     else
       match header "content-length" provisional with
       | "" ->
           let rec eof () =
             let s = recv c 65536 in
             if s <> "" then (
               ignore (capture s);
               require (Buffer.length wire <= 64 * 1024 * 1024) "Response limit";
               eof ())
           in
           eof ()
       | n -> ignore (capture (exact c (int_of_string n))));
  reference ~meth (Buffer.contents wire)

let request ?(body = "") ?(headers = []) ?(chunked = false) c meth path =
  let headers = ("host", "localhost") :: headers in
  let headers =
    if chunked then ("transfer-encoding", "chunked") :: headers
    else if body <> "" || meth = "POST" || meth = "PUT" then
      ("content-length", string_of_int (String.length body)) :: headers
    else headers
  in
  let head =
    Printf.sprintf "%s %s HTTP/1.1\r\n%s\r\n" meth path
      (String.concat ""
         (List.map (fun (k, v) -> k ^ ": " ^ v ^ "\r\n") headers))
  in
  send c head;
  if chunked then (
    let rec loop off =
      if off < String.length body then (
        let len = min 173 (String.length body - off) in
        send c (Printf.sprintf "%x\r\n%s\r\n" len (String.sub body off len));
        loop (off + len))
    in
    loop 0;
    send c "0\r\n\r\n")
  else send c body;
  response c meth

let exchange ?(half_close = false) port data =
  with_connection port (fun c ->
      send c data;
      if half_close then Unix.shutdown c.fd Unix.SHUTDOWN_SEND;
      let b = Buffer.create 1024 in
      let rec loop () =
        let s = recv c 65536 in
        if s <> "" then (
          Buffer.add_string b s;
          require (Buffer.length b < 1048576) "Response amplification";
          loop ())
      in
      loop ();
      Buffer.contents b)

let with_server ?(env = environment ()) ?stdin ~directory ~prefix command f =
  mkdir directory;
  let log = directory / "stdout.log" in
  Process.with_child ~env ?stdin ~log command (fun child ->
      let deadline = monotonic () +. 30. in
      let rec await () =
        require
          (Process.poll child = None)
          ("Server exited during startup: " ^ read log);
        let s = read log in
        match String.index_opt s '\n' with
        | Some i ->
            let first = String.sub s 0 i |> String.trim in
            require (starts ~prefix first) ("Invalid server readiness: " ^ first);
            String.sub first (String.length prefix)
              (String.length first - String.length prefix)
        | None ->
            require (monotonic () < deadline) "Server readiness timeout";
            sleep 0.01;
            await ()
      in
      let value = await () in
      f value child log)

(* Bounded streaming for load generators. Headers are checked by http/af; body
   bytes are checked incrementally by the workload oracle without retention. *)
let response_stream c meth on_chunk =
  let raw = head c in
  let parsed =
    match
      Angstrom.parse_string ~consume:All Httpaf.Httpaf_private.Parse.response
        raw
    with
    | Ok r -> r
    | Error e -> fail "Independent response head: %s" e
  in
  let r =
    {
      status = Httpaf.Status.to_code parsed.status;
      headers = List.rev (Httpaf.Headers.to_list parsed.headers);
      body = "";
    }
  in
  let transferred = ref 0 in
  let rec payload remaining =
    if remaining > 0 then (
      let data = exact c (min 8192 remaining) in
      transferred := !transferred + String.length data;
      require (!transferred <= 64 * 1024 * 1024) "Stream response bound";
      on_chunk data;
      payload (remaining - String.length data))
  in
  if meth <> "HEAD" && r.status <> 204 && r.status <> 304 && r.status >= 200
  then (
    if String.lowercase_ascii (header "transfer-encoding" r) = "chunked" then
      let rec chunks () =
        let h = String.trim (line c) in
        let size = List.hd (String.split_on_char ';' h) in
        let n = int_of_string ("0x" ^ size) in
        require (n >= 0 && n <= 64 * 1024 * 1024) "Chunk size limit";
        if n = 0 then ignore (head c)
        else (
          payload n;
          require (exact c 2 = "\r\n") "Chunk terminator";
          chunks ())
      in
      chunks ()
    else
      let length = header "content-length" r in
      require (length <> "") "Load response must be framed";
      payload (int_of_string length));
  (r, !transferred)

let start_request ?(headers = []) c meth path =
  send c
    (Printf.sprintf "%s %s HTTP/1.1\r\nhost: localhost\r\n%s\r\n" meth path
       (String.concat ""
          (List.map (fun (k, v) -> k ^ ": " ^ v ^ "\r\n") headers)))

let stream ?(slow = false) ?(after_first = fun () -> ()) c path expected =
  start_request c "GET" path;
  let first = ref true in
  let r, size =
    response_stream c "GET" (fun data ->
        require (String.for_all (( = ) 'x') data) "Stream corruption";
        if !first then (
          first := false;
          after_first ());
        if slow then sleep 0.001)
  in
  require (r.status = 200 && size = expected) "Stream status or length";
  size
