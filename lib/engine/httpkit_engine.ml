open Httpkit_core
module Timeout = Timeout
module Codec = Httpkit_http1

(* A per-instance identity avoids global mutable counters and rejects IDs from
   other connections even when their diagnostic sequence numbers match. *)
type id = { owner : unit ref; number : int64 }

let id_number id = id.number
let equal_id a b = a.owner == b.owner && a.number = b.number

type error =
  | Protocol of Codec.error
  | Invalid_command
  | Resource_limit
  | Cancelled

let error_to_string = function
  | Protocol e -> Codec.error_to_string e
  | Invalid_command -> "invalid engine command"
  | Resource_limit -> "engine resource limit"
  | Cancelled -> "cancelled"

type 'a submission = Accepted of 'a | Backpressured

type event =
  | Request of id * unit Request.t
  | Response of id * unit Response.t
  | Informational of id * unit Response.t
  | Data of id * string
  | Trailers of id * Headers.t
  | Complete of id
  | Body_aborted of id
  | Handoff of id
  | Closed of error option

(* Receive and transmit progress are independent: an incoming Complete does
   not imply that outgoing bytes have drained. Terminal receive reasons remain
   distinct so an early abort cannot be mistaken for a completed body. *)
type receiving =
  | Awaiting_head
  | Reading of Codec.body_decoder
  | Received
  | Aborted_input
  | Transferred_input

type sending = Awaiting_response | Writing of Codec.body_encoder | Sent

type exchange = {
  id : id;
  request : Codec.metadata;
  mutable receiving : receiving;
  mutable sending : sending;
  mutable final_sent : bool;
  mutable close_after : bool;
  mutable handoff : bool;
  mutable complete_pending : bool;
  mutable discard : bool;
  mutable continue_allowed : bool;
  mutable infos : int;
}

let receive_done a =
  match a.receiving with
  | Received | Aborted_input | Transferred_input -> true
  | Awaiting_head | Reading _ -> false

let send_done a = match a.sending with Sent -> true | _ -> false

let complete_input a =
  a.receiving <- Received;
  a.complete_pending <- true

let abort_input a =
  a.receiving <- Aborted_input;
  a.complete_pending <- false;
  a.close_after <- true

let complete_output a = a.sending <- Sent

type t = {
  server : bool;
  limits : Codec.limits;
  output_limit : int;
  info_limit : int;
  owner : unit ref;
  mutable next : int64;
  mutable active : exchange option;
  mutable head : Codec.head_decoder option;
  mutable head_started : bool;
  mutable pending : event option;
  output : string Queue.t;
  mutable offset : int;
  mutable queued : int;
  mutable stopped : bool;
  mutable shutting : bool;
  mutable peer_eof : bool;
}

let ( let* ) = Result.bind

let create server ?(limits = Codec.default_limits) ?(output_limit = 65536)
    ?(informational_limit = 16) () =
  if output_limit <= 0 || informational_limit < 0 then Error Resource_limit
  else
    Ok
      {
        server;
        limits;
        output_limit;
        info_limit = informational_limit;
        owner = ref ();
        next = 0L;
        active = None;
        head =
          (if server then Some (Codec.head_decoder ~limits Codec.Request)
           else None);
        head_started = false;
        pending = None;
        output = Queue.create ();
        offset = 0;
        queued = 0;
        stopped = false;
        shutting = false;
        peer_eof = false;
      }

let server = create true
let client = create false

let clear_output t =
  Queue.clear t.output;
  t.offset <- 0;
  t.queued <- 0

let close t reason =
  if not t.stopped then (
    t.stopped <- true;
    t.active <- None;
    t.head <- None;
    clear_output t;
    t.pending <- Some (Closed reason))

let abort t e = close t (Some e)

let protocol t e =
  abort t (Protocol e);
  Error (Protocol e)

let active t id =
  match t.active with
  | Some a when (not t.stopped) && equal_id id a.id -> Ok a
  | _ -> Error Invalid_command

let fresh t =
  if t.next = Int64.max_int then Error Resource_limit
  else (
    t.next <- Int64.succ t.next;
    Ok { owner = t.owner; number = t.next })

let empty = function Codec.Empty | Codec.Fixed 0L -> true | _ -> false

let request_method a =
  match a.request.head with
  | Codec.Request_head r -> Request.meth r
  | _ -> assert false

let request_headers a =
  match a.request.head with
  | Codec.Request_head r -> Request.headers r
  | _ -> assert false

let values name headers =
  List.map Header.Value.to_string
    (Headers.get_all (Result.get_ok (Header.Name.of_string name)) headers)

let connection_upgrade hs =
  List.exists
    (fun s ->
      List.exists
        (fun s -> String.lowercase_ascii (String.trim s) = "upgrade")
        (String.split_on_char ',' s))
    (values "connection" hs)

let upgrade_protocols hs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | s :: rest ->
        let s = String.trim s in
        let parts = String.split_on_char '/' s in
        if
          List.length parts > 2
          || not
               (List.for_all
                  (fun p -> Result.is_ok (Header.Name.of_string p))
                  parts)
        then Error (Protocol Codec.Invalid_field)
        else
          let normalized =
            match parts with
            | [ a ] -> String.lowercase_ascii a
            | [ a; b ] -> String.lowercase_ascii a ^ "/" ^ b
            | _ -> assert false
          in
          loop (normalized :: acc) rest
  in
  loop [] (List.concat_map (String.split_on_char ',') (values "upgrade" hs))

let validate_upgrade_request hs =
  let* protocols = upgrade_protocols hs in
  let has_protocol = protocols <> [] in
  let requests_upgrade = connection_upgrade hs in
  if has_protocol <> requests_upgrade then Error (Protocol Codec.Invalid_field)
  else Ok ()

let validate_handoff a response =
  let status = Status.to_int (Response.status response) in
  if
    Method.equal (request_method a) Method.connect
    && status >= 200 && status < 300
  then
    if empty a.request.framing then Ok ()
    else Error (Protocol Codec.Invalid_state)
  else if status = 101 && empty a.request.framing then
    let req = request_headers a and hs = Response.headers response in
    let* offered = upgrade_protocols req in
    let* selected = upgrade_protocols hs in
    if
      connection_upgrade req && connection_upgrade hs
      && match selected with [ p ] -> List.mem p offered | _ -> false
    then Ok ()
    else Error (Protocol Codec.Invalid_field)
  else Error (Protocol Codec.Invalid_state)

(* Reservation precedes every stateful encoder call: a rejected retry must not
   decrement a length counter or append a second copy of application data. *)
let reserve t n =
  if n > t.output_limit then Error Resource_limit
  else if n > t.output_limit - t.queued then Ok Backpressured
  else Ok (Accepted ())

let enqueue t s =
  if s <> "" then (
    Queue.add s t.output;
    t.queued <- t.queued + String.length s)

let body_event t a = function
  | Codec.Data bytes ->
      if not a.discard then t.pending <- Some (Data (a.id, bytes))
  | Codec.Trailers hs -> t.pending <- Some (Trailers (a.id, hs))
  | Codec.End -> complete_input a

(* Advance only work that requires no external bytes. In particular, retire an
   exchange only after its terminal input event and all output acknowledgements. *)
let settle t =
  if not t.stopped then (
    (match (t.active, t.pending) with
    | Some a, None when not (receive_done a) -> (
        match a.receiving with
        | Awaiting_head | Received | Aborted_input | Transferred_input -> ()
        | Reading d -> (
            match Codec.feed_body d "" ~off:0 ~len:0 with
            | Ok (_, Some e) -> body_event t a e
            | Ok (_, None) -> ()
            | Error e -> abort t (Protocol e)))
    | _ -> ());
    if (not t.stopped) && t.pending = None then
      match t.active with
      | Some a when a.complete_pending ->
          a.complete_pending <- false;
          t.pending <- Some (Complete a.id)
      | Some a when a.handoff && send_done a && t.queued = 0 ->
          t.stopped <- true;
          t.active <- None;
          t.head <- None;
          t.pending <- Some (Handoff a.id)
      | Some a when receive_done a && send_done a && t.queued = 0 ->
          if a.close_after || t.shutting || t.peer_eof then close t None
          else (
            t.active <- None;
            t.head_started <- false;
            t.head <-
              (if t.server then
                 Some (Codec.head_decoder ~limits:t.limits Codec.Request)
               else None))
      | None when t.shutting || t.peer_eof -> close t None
      | _ -> ())

let make_exchange id request incoming writer =
  {
    id;
    request;
    receiving =
      (match incoming with
      | None -> Awaiting_head
      | Some decoder -> Reading decoder);
    sending =
      (match writer with
      | None -> Awaiting_response
      | Some encoder -> Writing encoder);
    final_sent = false;
    close_after = not request.persistent;
    handoff = false;
    complete_pending = false;
    discard = false;
    continue_allowed = not request.expect_continue;
    infos = 0;
  }

let submit_request t request =
  settle t;
  if t.server || t.stopped || t.shutting then Error Invalid_command
  else if t.active <> None then Ok Backpressured
  else
    let* () = validate_upgrade_request (Request.headers request) in
    match Codec.encode_request ~limits:t.limits request with
    | Error e -> Error (Protocol e)
    | Ok (bytes, meta) -> (
        let* room = reserve t (String.length bytes) in
        match room with
        | Backpressured -> Ok Backpressured
        | Accepted () ->
            let* id = fresh t in
            let a =
              make_exchange id meta None
                (Some (Codec.body_encoder ~limits:t.limits meta))
            in
            a.final_sent <- true;
            t.active <- Some a;
            t.head <-
              Some
                (Codec.head_decoder ~limits:t.limits
                   (Codec.Response (Request.meth request)));
            enqueue t bytes;
            Ok (Accepted id))

let respond t id response =
  settle t;
  let* a = active t id in
  if (not t.server) || a.final_sent then Error Invalid_command
  else
    match
      Codec.encode_response ~limits:t.limits ~request_method:(request_method a)
        response
    with
    | Error e -> Error (Protocol e)
    | Ok (bytes, meta) -> (
        let status = Status.to_int (Response.status response) in
        let informational = status < 200 && status <> 101 in
        let* () =
          if meta.framing = Codec.Tunnel then
            validate_handoff a (Response.with_body () response)
          else Ok ()
        in
        if informational && a.infos >= t.info_limit then Error Resource_limit
        else
          let* room = reserve t (String.length bytes) in
          match room with
          | Backpressured -> Ok Backpressured
          | Accepted () ->
              enqueue t bytes;
              if informational then a.infos <- a.infos + 1
              else (
                a.final_sent <- true;
                a.close_after <-
                  a.close_after || (not meta.persistent) || t.shutting;
                if meta.framing = Codec.Tunnel then (
                  a.handoff <- true;
                  complete_output a)
                else (
                  a.sending <-
                    Writing (Codec.body_encoder ~limits:t.limits meta);
                  (* An early response cannot authorize reuse of unread upload bytes. *)
                  if not (receive_done a) then (
                    abort_input a;
                    t.pending <- Some (Body_aborted a.id))));
              settle t;
              Ok (Accepted ()))

(* Both data and final framing belong to the upload permission boundary. *)
let awaiting_continue t a = (not t.server) && not a.continue_allowed

let send_data t id bytes =
  let* a = active t id in
  if send_done a then Error Invalid_command
  else
    match a.sending with
    | Awaiting_response | Sent -> Error Invalid_command
    | Writing writer -> (
        if awaiting_continue t a then Ok Backpressured
        else
          let overhead = 32 in
          if String.length bytes > max_int - overhead then Error Resource_limit
          else
            let* room = reserve t (String.length bytes + overhead) in
            match room with
            | Backpressured -> Ok Backpressured
            | Accepted () -> (
                match Codec.encode_data writer bytes with
                | Error e -> protocol t e
                | Ok wire ->
                    enqueue t wire;
                    Ok (Accepted ())))

let finish ?(trailers = Headers.empty) t id =
  let* a = active t id in
  if send_done a then Error Invalid_command
  else
    match a.sending with
    | Awaiting_response | Sent -> Error Invalid_command
    | Writing writer -> (
        if awaiting_continue t a then Ok Backpressured
        else if Headers.wire_bytes trailers > max_int - 5 then
          Error Resource_limit
        else
          let* room = reserve t (Headers.wire_bytes trailers + 5) in
          match room with
          | Backpressured -> Ok Backpressured
          | Accepted () -> (
              match Codec.finish_body ~trailers writer with
              | Error e -> protocol t e
              | Ok wire ->
                  enqueue t wire;
                  complete_output a;
                  settle t;
                  Ok (Accepted ())))

let continue_request t id =
  let* a = active t id in
  if t.server || send_done a then Error Invalid_command
  else (
    a.continue_allowed <- true;
    Ok ())

let discard_body t id =
  let* a = active t id in
  a.discard <- true;
  (match t.pending with
  | Some (Data (id', _)) when equal_id id id' -> t.pending <- None
  | _ -> ());
  settle t;
  Ok ()

let receive_head t meta =
  t.head <- None;
  t.head_started <- false;
  match (meta.Codec.head, t.active) with
  | Codec.Request_head request, None when t.server ->
      let* () = validate_upgrade_request (Request.headers request) in
      let* id = fresh t in
      let a =
        make_exchange id meta
          (Some (Codec.body_decoder ~limits:t.limits meta))
          None
      in
      if empty meta.framing then complete_input a;
      t.active <- Some a;
      t.pending <- Some (Request (id, request));
      Ok ()
  | Codec.Response_head response, Some a when not t.server ->
      let status = Status.to_int (Response.status response) in
      if status < 200 && status <> 101 then
        if a.infos >= t.info_limit then Error Resource_limit
        else (
          a.infos <- a.infos + 1;
          if status = 100 then a.continue_allowed <- true;
          t.head <-
            Some
              (Codec.head_decoder ~limits:t.limits
                 (Codec.Response (request_method a)));
          t.pending <- Some (Informational (a.id, response));
          Ok ())
      else
        let* () =
          if meta.framing = Codec.Tunnel then validate_handoff a response
          else Ok ()
        in
        a.close_after <- a.close_after || not meta.persistent;
        if meta.framing = Codec.Tunnel then (
          a.handoff <- true;
          a.receiving <- Transferred_input;
          complete_output a)
        else (
          (* Finishing the encoder does not acknowledge transport output. A
             closing final response also cancels a finalized, queued upload.
             Already acknowledged bytes cannot be recalled, so force close. *)
          if not (send_done a) || (not meta.persistent && t.queued > 0) then (
            complete_output a;
            a.close_after <- true;
            clear_output t);
          a.receiving <- Reading (Codec.body_decoder ~limits:t.limits meta);
          if empty meta.framing then complete_input a);
        t.pending <- Some (Response (a.id, response));
        Ok ()
  | _ -> Error Invalid_command

let offer t bytes ~off ~len =
  if
    off < 0 || len < 0
    || off > String.length bytes
    || len > String.length bytes - off
  then Error Invalid_command
  else (
    settle t;
    if t.stopped || t.peer_eof then Error Invalid_command
    else if t.pending <> None then Ok 0
    else
      match (t.head, t.active) with
      | Some decoder, _ -> (
          match Codec.feed_head decoder bytes ~off ~len with
          | Error e -> protocol t e
          | Ok (n, None) ->
              if n > 0 then t.head_started <- true;
              Ok n
          | Ok (n, Some meta) -> (
              match receive_head t meta with
              | Error e ->
                  abort t e;
                  Error e
              | Ok () -> Ok n))
      | None, Some a when not (receive_done a) -> (
          match a.receiving with
          | Awaiting_head | Received | Aborted_input | Transferred_input -> Ok 0
          | Reading decoder -> (
              match Codec.feed_body decoder bytes ~off ~len with
              | Error e -> protocol t e
              | Ok (n, event) ->
                  Option.iter (body_event t a) event;
                  settle t;
                  Ok n))
      | None, None when (not t.server) && len > 0 ->
          protocol t Codec.Invalid_state
      | _ -> Ok 0)

let poll_event t =
  settle t;
  let event = t.pending in
  t.pending <- None;
  settle t;
  event

let output t =
  if Queue.is_empty t.output then None
  else
    let bytes = Queue.peek t.output in
    Some (bytes, t.offset, String.length bytes - t.offset)

let acknowledge t count =
  match output t with
  | None -> Error Invalid_command
  | Some (bytes, _, len) ->
      if count < 0 || count > len then Error Invalid_command
      else (
        t.offset <- t.offset + count;
        t.queued <- t.queued - count;
        if t.offset = String.length bytes then (
          ignore (Queue.take t.output);
          t.offset <- 0);
        settle t;
        Ok ())

let input_eof t =
  if t.stopped then Ok ()
  else (
    t.peer_eof <- true;
    match (t.active, t.head) with
    | None, _ when not t.head_started ->
        close t None;
        Ok ()
    | Some a, _ when receive_done a ->
        a.close_after <- true;
        settle t;
        Ok ()
    | Some a, None -> (
        match a.receiving with
        | Awaiting_head | Received | Aborted_input | Transferred_input ->
            protocol t Codec.Unexpected_eof
        | Reading d -> (
            match Codec.eof_body d with
            | Error e -> protocol t e
            | Ok event ->
                Option.iter (body_event t a) event;
                a.close_after <- true;
                settle t;
                Ok ()))
    | _, Some d -> (
        match Codec.eof_head d with
        | Error e -> protocol t e
        | Ok () ->
            settle t;
            Ok ())
    | _ -> protocol t Codec.Unexpected_eof)

let shutdown t =
  t.shutting <- true;
  Option.iter (fun a -> a.close_after <- true) t.active;
  settle t

let queued_output_bytes t = t.queued

let queued_input_bytes t =
  match t.pending with Some (Data (_, bytes)) -> String.length bytes | _ -> 0

let input_state t =
  settle t;
  if t.stopped || t.peer_eof then `Closed
  else if t.pending <> None then `Blocked
  else
    match (t.head, t.active) with
    | Some _, None when t.server && not t.head_started -> `Idle
    | Some _, _ -> `Head
    | None, Some a when match a.receiving with Reading _ -> true | _ -> false ->
        `Body
    | _ -> `Blocked

let max_send_size t =
  max 0 (min (Codec.step_limit t.limits) (t.output_limit - 32))
