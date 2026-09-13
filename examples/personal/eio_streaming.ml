(* Both directions stream incrementally; neither side retains a complete body. *)
open Httpkit_core
module A = Httpkit_transport_eio
module E = Httpkit_engine

let ok = Result.get_ok
let chunk = String.make 8192 'x'
let chunks = 128
let bytes = chunks * String.length chunk

let receive c id =
  let rec loop total =
    match A.next_event c with
    | E.Data (owner, data) when E.equal_id owner id ->
        if not (String.for_all (( = ) 'x') data) then failwith "corrupt stream";
        if String.length data > bytes - total then failwith "oversized stream";
        loop (total + String.length data)
    | E.Trailers (owner, _) when E.equal_id owner id -> loop total
    | E.Complete owner when E.equal_id owner id ->
        if total <> bytes then failwith "truncated stream"
    | _ -> failwith "unexpected stream event"
  in
  loop 0

let transmit c id =
  for _ = 1 to chunks do
    A.send c id chunk
  done;
  A.finish c id

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let a, b = Eio_unix.Net.socketpair_stream ~sw () in
          let clock = Eio.Stdenv.mono_clock env in
          let limits = ok (E.Codec.limits ~body:(Int64.of_int bytes) ()) in
          Eio.Fiber.both
            (fun () ->
              A.with_connection ~clock (A.of_flow a)
                (ok (E.server ~limits ~output_limit:32768 ()))
                (fun c ->
                  let id =
                    match A.next_event c with
                    | E.Request (id, _) -> id
                    | _ -> assert false
                  in
                  receive c id;
                  A.respond c id
                    (Response.create ~status:Status.ok
                       ~headers:
                         (ok
                            (Headers.of_list
                               [ ("transfer-encoding", "chunked") ]))
                       ());
                  transmit c id))
            (fun () ->
              A.with_connection ~clock (A.of_flow b)
                (ok (E.client ~limits ~output_limit:32768 ()))
                (fun c ->
                  let request =
                    Request.create ~meth:Method.post
                      ~target:(ok (Target.of_string "/upload"))
                      ~headers:
                        (ok
                           (Headers.of_list
                              [
                                ("host", "localhost");
                                ("content-length", string_of_int bytes);
                              ]))
                      ()
                  in
                  let id = A.submit_request c request in
                  transmit c id;
                  (match A.next_event c with
                  | E.Response (owner, r)
                    when E.equal_id owner id && Response.status r = Status.ok ->
                      ()
                  | _ -> assert false);
                  receive c id;
                  A.shutdown c));
          Printf.printf "Streamed %d bytes each way\n" bytes))
