open Httpkit_core
module E = Httpkit_engine

let ok = Result.get_ok

let accepted = function
  | Ok (E.Accepted x) -> x
  | _ -> Crowbar.fail "unexpected submission"

let connection body =
  let engine = ok (E.server ~output_limit:4096 ()) in
  let head = "GET / HTTP/1.1\r\nHost: x\r\n\r\n" in
  assert (
    ok (E.offer engine head ~off:0 ~len:(String.length head))
    = String.length head);
  let id =
    match E.poll_event engine with
    | Some (E.Request (id, _)) -> id
    | _ -> assert false
  in
  assert (E.poll_event engine = Some (E.Complete id));
  let response =
    Response.create ~status:Status.ok
      ~headers:
        (ok
           (Headers.of_list
              [ ("content-length", string_of_int (String.length body)) ]))
      ()
  in
  (engine, id, response)

let write engine id response body =
  accepted (E.respond engine id response);
  accepted (E.send_data engine id body);
  accepted (E.finish engine id)

let expected body =
  "HTTP/1.1 200 \r\ncontent-length: "
  ^ string_of_int (String.length body)
  ^ "\r\n\r\n" ^ body

let drain schedule engine =
  let out = Buffer.create 64 and index = ref 0 in
  let rec loop () =
    match E.output engine with
    | None ->
        Crowbar.check (E.queued_output_bytes engine = 0);
        Buffer.contents out
    | Some (bytes, off, len) ->
        Crowbar.check (E.queued_output_bytes engine <= 4096);
        let before = E.output engine in
        Crowbar.check (E.acknowledge engine (-1) = Error E.Invalid_command);
        Crowbar.check (E.output engine = before);
        ignore (ok (E.acknowledge engine 0));
        Crowbar.check (E.output engine = before);
        let step =
          if schedule = "" then 1
          else 1 + Char.code schedule.[!index mod String.length schedule]
        in
        let n = min len step in
        Buffer.add_substring out bytes off n;
        ignore (ok (E.acknowledge engine n));
        incr index;
        Crowbar.check (!index <= 8192);
        loop ()
  in
  loop ()

let partial bytes =
  let e, id, r = connection bytes in
  write e id r bytes;
  Crowbar.check (drain bytes e = expected bytes)

let isolation bytes =
  let a, aid, ar = connection ("a" ^ bytes)
  and b, bid, br = connection ("b" ^ bytes) in
  Crowbar.check (not (E.equal_id aid bid));
  Crowbar.check (E.respond a bid ar = Error E.Invalid_command);
  Crowbar.check (E.respond b aid br = Error E.Invalid_command);
  write a aid ar ("a" ^ bytes);
  write b bid br ("b" ^ bytes);
  Crowbar.check (drain bytes b = expected ("b" ^ bytes));
  Crowbar.check (drain bytes a = expected ("a" ^ bytes));
  (* A/B/A executions create fresh owners and must produce identical transcripts. *)
  partial bytes;
  partial
    (String.init (String.length bytes) (fun i ->
         bytes.[String.length bytes - i - 1]));
  partial bytes

let () =
  let selected = Sys.getenv_opt "HTTP_KIT_FUZZ_CASE" in
  if not (List.mem selected [ None; Some "partial-write"; Some "isolation" ])
  then invalid_arg "unknown fuzz case";
  List.iter
    (fun (name, run) ->
      if selected = None || selected = Some name then
        Crowbar.add_test ~name [ Crowbar.bytes ] (fun bytes ->
            if String.length bytes <= 1024 then run bytes))
    [ ("partial-write", partial); ("isolation", isolation) ]
