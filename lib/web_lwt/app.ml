open Lwt.Infix
open Httpkit_core
module A = Httpkit_transport_lwt
module E = Httpkit_engine
module R = Httpkit_router
module W = Httpkit

type request = {
  head : unit Request.t;
  params : (string * string) list;
  read_next : unit -> string option Lwt.t;
  request_id : string;
  peer : string;
}

type payload =
  | Fixed of string
  | Streaming of ((string -> unit Lwt.t) -> unit Lwt.t)
  | Upgrade of (A.transport -> string -> unit Lwt.t)

type response = payload Response.t
type handler = request -> response Lwt.t
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
    read r >>= function
    | None -> Lwt.return (Buffer.contents b)
    | Some s ->
        if String.length s > limit - Buffer.length b then
          Lwt.fail (A.Error (A.Engine E.Resource_limit))
        else (
          Buffer.add_string b s;
          loop ())
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
  if content_type r <> Some "application/json" then
    Lwt.return (Error W.Json.Invalid_json)
  else body ~limit r >|= W.Json.parse ~max_bytes:limit

let form ?(limit = 1048576) r =
  if content_type r <> Some "application/x-www-form-urlencoded" then
    Lwt.return (Error W.Url.Invalid_byte)
  else body ~limit r >|= W.Url.pairs ~max_bytes:limit

let multipart r parser =
  let rec loop () =
    read r >>= function
    | None -> Lwt.return (W.Multipart.finish parser)
    | Some s -> (
        match W.Multipart.feed parser s with
        | Error _ as e -> Lwt.return e
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
  | Ok h -> Response.with_body (Upgrade callback) h

let map_headers f r = Response.with_headers (f (Response.headers r)) r
let status r = Status.to_int (Response.status r)

let route meth pattern handler =
  R.route ~meth (Result.get_ok (R.pattern pattern)) handler

let routes ?(middleware = []) entries =
  let table = Result.get_ok (R.compile entries) in
  let dispatch r =
    let meth = Request.meth r.head and target = Request.target r.head in
    let lookup meth = R.lookup table ~meth ~target in
    let outcome =
      match lookup meth with
      | Ok (R.Method_not_allowed _) when meth = Method.head -> lookup Method.get
      | outcome -> outcome
    in
    match outcome with
    | Ok (R.Matched m) -> m.value { r with params = R.Params.to_list m.params }
    | Ok R.Not_found ->
        Lwt.return (reply (W.Reply.text ~status:404 "Not found\n"))
    | Ok (R.Method_not_allowed methods) ->
        let methods =
          if List.mem Method.get methods && not (List.mem Method.head methods)
          then methods @ [ Method.head ]
          else methods
        in
        Lwt.return
          (reply
             (W.Reply.make ~status:405
                ~headers:
                  [
                    ( "allow",
                      String.concat ", " (List.map Method.to_string methods) );
                  ]
                "Method not allowed\n"))
    | Error _ ->
        Lwt.return (reply (W.Reply.text ~status:400 "Invalid target\n"))
  in
  List.fold_right (fun wrapper next -> wrapper next) middleware dispatch

let exchange ~body_limit ~random ~on_error handler c id head peer =
  let complete = ref false
  and busy = ref false
  and started = ref false
  and alive = ref true
  and granted = ref false
  and total = ref 0 in
  let rec next () =
    A.next_event c >>= function
    | E.Data (owner, data) when E.equal_id owner id ->
        if String.length data > body_limit - !total then
          Lwt.fail (A.Error (A.Engine E.Resource_limit))
        else (
          total := !total + String.length data;
          Lwt.return_some data)
    | E.Trailers (owner, _) when E.equal_id owner id -> next ()
    | E.Complete owner when E.equal_id owner id ->
        complete := true;
        Lwt.return_none
    | E.Closed _ | E.Body_aborted _ -> Lwt.fail End_of_file
    | _ -> Lwt.fail_with "unexpected body event"
  in
  let read_next () =
    if not !alive then invalid_arg "expired request body";
    if !busy then invalid_arg "concurrent body readers";
    if !complete then Lwt.return_none
    else (
      busy := true;
      Lwt.finalize
        (fun () ->
          (if
             (not !granted) && (not !started)
             && W.Reply.header_values "expect" (Request.headers head) <> []
           then (
             granted := true;
             A.respond c id
               (Response.create ~status:(Result.get_ok (Status.of_int 100)) ()))
           else Lwt.return_unit)
          >>= next)
        (fun () ->
          busy := false;
          Lwt.return_unit))
  in
  Lwt.finalize
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
      Lwt.catch
        (fun () -> handler request)
        (function
          | (Lwt.Canceled | A.Error _ | End_of_file) as exn -> Lwt.fail exn
          | exn ->
              on_error exn >|= fun () ->
              reply (W.Reply.text ~status:500 "Internal server error\n"))
      >>= fun response ->
      let response =
        W.Reply.set_header "x-request-id" request.request_id response
      in
      match Response.body response with
      | Upgrade callback -> (
          body ~limit:0 request >>= fun _ ->
          A.respond c id response >>= fun () ->
          A.next_event c >>= function
          | E.Handoff owner when E.equal_id owner id ->
              let transport, suffix = A.take_handoff c in
              Lwt.return_some (transport, suffix, callback)
          | _ -> Lwt.fail_with "missing protocol handoff")
      | Fixed _ | Streaming _ ->
          started := true;
          A.respond c id response >>= fun () ->
          (if Request.meth head = Method.head then Lwt.return_unit
           else
             match Response.body response with
             | Fixed data -> A.send c id data
             | Streaming produce -> produce (fun data -> A.send c id data)
             | Upgrade _ -> assert false)
          >>= fun () ->
          A.finish c id >>= fun () ->
          (if not !complete then A.discard_body c id else Lwt.return_unit)
          >|= fun () -> None)
    (fun () ->
      alive := false;
      Lwt.return_unit)

let within = Deadline.within

let connection ~peer ~body_limit ~random ~on_error ~clock ~request_timeout
    handler c =
  let rec loop () =
    A.next_event c >>= function
    | E.Request (id, head) -> (
        within clock request_timeout (fun () ->
            exchange ~body_limit ~random ~on_error handler c id head peer)
        >>= function
        | None -> loop ()
        | Some _ as h -> Lwt.return h)
    | E.Closed _ -> Lwt.return_none
    | E.Complete _ | E.Body_aborted _ -> loop ()
    | _ -> Lwt.fail_with "unexpected application event"
  in
  loop ()

let serve ?(max_connections = 16) ?(body_limit = 1048576)
    ?(output_limit = 32768) ?limits ?policy ?(request_timeout = 60.) ?observe
    ~clock ~random ~stop ~accept ~on_error handler =
  if
    max_connections <= 0 || body_limit < 0 || output_limit <= 0
    || (not (Float.is_finite request_timeout))
    || request_timeout <= 0.
  then invalid_arg "server limits";
  let engine () = Result.get_ok (E.server ~output_limit ?limits ()) in
  ignore (engine ());
  let observation = Runtime_observer.create ?observe ~now:clock.A.now () in
  let connections = ref [] and stopping = ref false in
  let rec worker () =
    if !stopping then Lwt.return_unit
    else
      accept () >>= fun ((transport : A.transport), peer) ->
      Runtime_observer.connection observation transport (fun transport ->
          if !stopping then transport.close ()
          else
            Lwt.catch
              (fun () ->
                A.with_connection ?policy ~clock transport (engine ()) (fun c ->
                    connections := c :: !connections;
                    Lwt.finalize
                      (fun () ->
                        connection ~peer ~body_limit ~random ~on_error ~clock
                          ~request_timeout handler c)
                      (fun () ->
                        connections :=
                          List.filter (fun x -> x != c) !connections;
                        Lwt.return_unit))
                >>= function
                | None -> Lwt.return_unit
                | Some (transport, suffix, callback) ->
                    Lwt.finalize
                      (fun () -> callback transport suffix)
                      transport.close)
              (function
                | Lwt.Canceled as exn -> Lwt.fail exn | exn -> on_error exn))
      >>= worker
  in
  let workers = List.init max_connections (fun _ -> Lwt.apply worker ()) in
  let drain =
    Lwt.protected stop >>= fun () ->
    stopping := true;
    Runtime_observer.shutdown observation;
    Lwt_list.iter_p
      (fun c ->
        Lwt.catch
          (fun () -> A.shutdown c)
          (function Lwt.Canceled as e -> Lwt.fail e | e -> on_error e))
      !connections
  in
  Lwt.finalize
    (fun () -> Lwt.pick [ Lwt.join workers; drain ])
    (fun () ->
      stopping := true;
      List.iter Lwt.cancel workers;
      Lwt.cancel drain;
      Lwt.join
        (List.map
           (fun p -> Lwt.catch (fun () -> p) (fun _ -> Lwt.return_unit))
           workers))
