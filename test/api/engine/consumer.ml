open Httpkit_core
open Httpkit_engine

let ok = Result.get_ok

let () =
  let connection = ok (server ()) in
  let input = "GET / HTTP/1.1\r\nHost: x\r\n\r\n" in
  assert (
    ok (offer connection input ~off:0 ~len:(String.length input))
    = String.length input);
  let id =
    match poll_event connection with
    | Some (Request (id, _)) -> id
    | _ -> assert false
  in
  assert (poll_event connection = Some (Complete id));
  let response =
    Response.create ~status:Status.ok
      ~headers:(ok (Headers.of_list [ ("content-length", "3") ]))
      ()
  in
  assert (ok (respond connection id response) = Accepted ());
  assert (ok (send_data connection id "abc") = Accepted ());
  assert (ok (finish connection id) = Accepted ());
  let rec flush () =
    match output connection with
    | None -> ()
    | Some (bytes, off, len) ->
        print_string (String.sub bytes off len);
        ignore (ok (acknowledge connection len));
        flush ()
  in
  flush ()
