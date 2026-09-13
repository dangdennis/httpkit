open Httpkit_core
module E = Httpkit_engine

let ok = Result.get_ok

let accepted = function
  | Ok (E.Accepted x) -> x
  | _ -> failwith "unexpected backpressure"

let sample size =
  let engine = ok (E.server ~output_limit:32768 ()) in
  let input = "GET / HTTP/1.1\r\nHost: x\r\n\r\n" in
  ignore (ok (E.offer engine input ~off:0 ~len:(String.length input)));
  let id =
    match E.poll_event engine with
    | Some (E.Request (id, _)) -> id
    | _ -> assert false
  in
  assert (E.poll_event engine = Some (E.Complete id));
  let response =
    Response.create ~status:Status.ok
      ~headers:(ok (Headers.of_list [ ("content-length", string_of_int size) ]))
      ()
  in
  accepted (E.respond engine id response);
  let maximum = ref 0 and acknowledged = ref 0 in
  let drain () =
    let rec loop () =
      match E.output engine with
      | None -> ()
      | Some (_, _, len) ->
          maximum := max !maximum (E.queued_output_bytes engine);
          assert (!maximum <= 32768);
          let n = min 997 len in
          ignore (ok (E.acknowledge engine n));
          acknowledged := !acknowledged + n;
          loop ()
    in
    loop ()
  in
  drain ();
  let header_bytes = !acknowledged in
  let chunk = String.make 8192 'a' in
  Gc.full_major ();
  let before = Gc.allocated_bytes () and start = Mtime_clock.counter () in
  let rec send remaining =
    if remaining > 0 then
      let n = min remaining 8192 in
      let data = if n = 8192 then chunk else String.sub chunk 0 n in
      match E.send_data engine id data with
      | Ok (E.Accepted ()) -> send (remaining - n)
      | Ok E.Backpressured ->
          drain ();
          send remaining
      | _ -> failwith "send failed"
  in
  send size;
  drain ();
  accepted (E.finish engine id);
  drain ();
  let ns = Mtime.Span.to_float_ns (Mtime_clock.count start)
  and allocated = Gc.allocated_bytes () -. before in
  assert (!acknowledged - header_bytes = size);
  Gc.full_major ();
  Printf.sprintf
    "{\"body_bytes\":%d,\"ns\":%.3f,\"allocated_bytes\":%.0f,\"peak_engine_output_bytes\":%d,\"post_major_live_words\":%d}"
    size ns allocated !maximum (Gc.stat ()).live_words

let () =
  Printf.printf
    "{\"compiler\":%S,\"profile\":\"uninstrumented\",\"results\":[%s]}\n"
    Sys.ocaml_version
    (String.concat "," (List.map sample [ 65536; 1048576; 16777216 ]))
