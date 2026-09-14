open Httpkit_core
module A = Httpkit_transport_eio
module E = Httpkit_engine
module R = Httpkit_router
module W = Httpkit

type request = {
  head : unit Request.t;
  params : (string * string) list;
  read_next : unit -> string option;
  request_id : string;
  peer : string;
}

type payload =
  | Fixed of string
  | Streaming of ((string -> unit) -> unit)
  | Upgrade of (A.transport -> string -> unit)

type response = payload Response.t
type handler = request -> response
type middleware = handler -> handler

let head r = r.head
let params r = r.params
let param name r = List.assoc_opt name r.params
let request_id r = r.request_id
let peer r = r.peer
let read r = r.read_next ()

let body ?(limit = 1048576) r =
  if limit < 0 then invalid_arg "body limit";
  let b = Buffer.create (min limit 4096) in
  let rec loop () =
    match read r with
    | None -> Buffer.contents b
    | Some s ->
        if String.length s > limit - Buffer.length b then
          raise (A.Error (A.Engine E.Resource_limit));
        Buffer.add_string b s;
        loop ()
  in
  loop ()

let content_type r =
  match W.Reply.header_values "content-type" (Request.headers r.head) with
  | [ v ] ->
      Some
        (String.lowercase_ascii
           (String.trim (List.hd (String.split_on_char ';' v))))
  | _ -> None

let json ?(limit = 1048576) r =
  if content_type r <> Some "application/json" then Error W.Json.Invalid_json
  else W.Json.parse ~max_bytes:limit (body ~limit r)

let form ?(limit = 1048576) r =
  if content_type r <> Some "application/x-www-form-urlencoded" then
    Error W.Url.Invalid_byte
  else W.Url.pairs ~max_bytes:limit (body ~limit r)

let multipart r parser =
  let rec loop () =
    match read r with
    | None -> W.Multipart.finish parser
    | Some data -> (
        match W.Multipart.feed parser data with
        | Error _ as e -> e
        | Ok () -> loop ())
  in
  loop ()

let reply r = Response.map_body (fun s -> Fixed s) r

let stream ?(status = 200) ?(headers = []) f =
  if status < 200 || status > 599 || List.mem status [ 204; 205; 304 ] then
    invalid_arg "stream status";
  if
    List.exists
      (fun (n, _) ->
        List.mem (String.lowercase_ascii n)
          [ "content-length"; "transfer-encoding" ])
      headers
  then invalid_arg "stream framing";
  Response.create
    ~status:(Result.get_ok (Status.of_int status))
    ~headers:
      (Result.get_ok
         (Headers.of_list (headers @ [ ("transfer-encoding", "chunked") ])))
    (Streaming f)

let websocket ~allowed_origins r callback =
  match W.Websocket.handshake ~allowed_origins r.head with
  | Error _ -> reply (W.Reply.text ~status:400 "Invalid WebSocket handshake\n")
  | Ok head -> Response.with_body (Upgrade callback) head

let map_headers f r = Response.with_headers (f (Response.headers r)) r
let status r = Status.to_int (Response.status r)

let route meth pattern handler =
  R.route ~meth (Result.get_ok (R.pattern pattern)) handler

let routes ?(middleware = []) entries =
  let table = Result.get_ok (R.compile entries) in
  let dispatch request =
    let meth = Request.meth request.head
    and target = Request.target request.head in
    let lookup meth = R.lookup table ~meth ~target in
    let outcome =
      match lookup meth with
      | Ok (R.Method_not_allowed _) when meth = Method.head -> lookup Method.get
      | outcome -> outcome
    in
    match outcome with
    | Ok (R.Matched m) ->
        m.value { request with params = R.Params.to_list m.params }
    | Ok R.Not_found -> reply (W.Reply.text ~status:404 "Not found\n")
    | Ok (R.Method_not_allowed methods) ->
        let methods =
          if List.mem Method.get methods && not (List.mem Method.head methods)
          then methods @ [ Method.head ]
          else methods
        in
        reply
          (W.Reply.make ~status:405
             ~headers:
               [
                 ( "allow",
                   String.concat ", " (List.map Method.to_string methods) );
               ]
             "Method not allowed\n")
    | Error _ -> reply (W.Reply.text ~status:400 "Invalid target\n")
  in
  List.fold_right (fun wrapper next -> wrapper next) middleware dispatch

let exchange ~body_limit ~random ~on_error handler c id head =
  let complete = ref false and busy = ref false and started = ref false in
  let total = ref 0 and granted = ref false and alive = ref true in
  let rec next () =
    match A.next_event c with
    | E.Data (owner, data) when E.equal_id owner id ->
        if String.length data > body_limit - !total then
          raise (A.Error (A.Engine E.Resource_limit));
        total := !total + String.length data;
        Some data
    | E.Trailers (owner, _) when E.equal_id owner id -> next ()
    | E.Complete owner when E.equal_id owner id ->
        complete := true;
        None
    | E.Closed _ | E.Body_aborted _ -> raise End_of_file
    | _ -> failwith "unexpected body event"
  in
  let read_next () =
    if not !alive then invalid_arg "expired request body";
    if !busy then invalid_arg "concurrent body readers";
    if !complete then None
    else (
      busy := true;
      Fun.protect
        ~finally:(fun () -> busy := false)
        (fun () ->
          if
            (not !granted) && (not !started)
            && W.Reply.header_values "expect" (Request.headers head) <> []
          then (
            granted := true;
            A.respond c id
              (Response.create ~status:(Result.get_ok (Status.of_int 100)) ()));
          next ()))
  in
  fun peer ->
    Fun.protect
      ~finally:(fun () -> alive := false)
      (fun () ->
        let raw = random 16 in
        if String.length raw <> 16 then invalid_arg "request ID entropy";
        let request =
          {
            head;
            params = [];
            read_next;
            peer;
            request_id =
              Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
                raw;
          }
        in
        let response =
          try handler request with
          | (Eio.Cancel.Cancelled _ | A.Error _ | End_of_file) as exn ->
              raise exn
          | exn ->
              on_error exn;
              reply (W.Reply.text ~status:500 "Internal server error\n")
        in
        let response =
          W.Reply.set_header "x-request-id" request.request_id response
        in
        match Response.body response with
        | Upgrade callback -> (
            ignore (body ~limit:0 request);
            A.respond c id response;
            match A.next_event c with
            | E.Handoff owner when E.equal_id owner id ->
                let transport, suffix = A.take_handoff c in
                Some (transport, suffix, callback)
            | _ -> failwith "missing protocol handoff")
        | Fixed _ | Streaming _ ->
            started := true;
            A.respond c id response;
            (if Request.meth head <> Method.head then
               match Response.body response with
               | Fixed data -> A.send c id data
               | Streaming produce -> produce (fun data -> A.send c id data)
               | Upgrade _ -> assert false);
            A.finish c id;
            if not !complete then A.discard_body c id;
            None)

let connection ~peer ~body_limit ~random ~on_error ~timeout handler c =
  let rec loop () =
    match A.next_event c with
    | E.Request (id, head) -> (
        match
          Eio.Time.Timeout.run_exn timeout (fun () ->
              exchange ~body_limit ~random ~on_error handler c id head peer)
        with
        | None -> loop ()
        | Some _ as handoff -> handoff)
    | E.Closed _ -> None
    | E.Complete _ | E.Body_aborted _ -> loop ()
    | _ -> failwith "unexpected application event"
  in
  loop ()

let serve ?(max_connections = 16) ?(body_limit = 1048576)
    ?(output_limit = 32768) ?limits ?policy ?(request_timeout = 60.) ~clock
    ~random ~stop ~accept ~on_error handler =
  if
    max_connections <= 0 || body_limit < 0 || output_limit <= 0
    || (not (Float.is_finite request_timeout))
    || request_timeout <= 0.
  then invalid_arg "server limits";
  let engine () = Result.get_ok (E.server ~output_limit ?limits ()) in
  ignore (engine ());
  let timeout = Eio.Time.Timeout.seconds clock request_timeout in
  let connections = ref [] and stopping = ref false in
  let worker () =
    let rec loop () =
      if !stopping then Eio.Fiber.await_cancel ();
      let (transport : A.transport), peer = accept () in
      if !stopping then (
        transport.close ();
        Eio.Fiber.await_cancel ());
      (try
         let upgraded =
           A.with_connection ?policy ~clock transport (engine ()) (fun c ->
               connections := c :: !connections;
               Fun.protect
                 ~finally:(fun () ->
                   connections := List.filter (fun x -> x != c) !connections)
                 (fun () ->
                   connection ~peer ~body_limit ~random ~on_error ~timeout
                     handler c))
         in
         match upgraded with
         | None -> ()
         | Some (transport, suffix, callback) ->
             Fun.protect ~finally:transport.close (fun () ->
                 callback transport suffix)
       with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> on_error exn);
      loop ()
    in
    loop ()
  in
  Eio.Fiber.first
    (fun () -> Eio.Fiber.all (List.init max_connections (fun _ -> worker)))
    (fun () ->
      Eio.Promise.await stop;
      stopping := true;
      Eio.Fiber.all
        (List.map
           (fun c () ->
             try A.shutdown c with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> on_error exn)
           !connections))
