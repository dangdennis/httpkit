open Http_kit_core
open Suite_support
module H = Http_kit_http1

let kit_fields fields =
  List.map
    (fun field ->
      ( Header.Name.to_string (Header.name field),
        Header.Value.to_string (Header.value field) ))
    (Headers.to_list fields)

let check_fields actual expected =
  if actual <> expected then
    failwith
      ("field mismatch: "
      ^ String.concat ";" (List.map (fun (k, v) -> k ^ "=" ^ v) actual))

let fragments step wire =
  List.init
    ((String.length wire + step - 1) / step)
    (fun i ->
      let off = i * step in
      String.sub wire off (min step (String.length wire - off)))

(* These upstream entry points intentionally expose raw head parsers. They are
   version-pinned benchmark dependencies, never production dependencies. Their
   parse result is NOT proof of http-kit's authority/framing/limit policies. *)
let angstrom parser chunks =
  let state =
    List.fold_left
      (fun state chunk ->
        (match state with
        | Angstrom.Buffered.Partial _ -> ()
        | _ -> failwith "early parser completion");
        Angstrom.Buffered.feed state (`String chunk))
      (Angstrom.Buffered.parse parser)
      chunks
  in
  match state with
  | Angstrom.Buffered.Done (rest, result) ->
      require (rest.len = 0);
      result
  | _ -> failwith "upstream parser did not consume the complete head"

let kit role chunks =
  let decoder = H.head_decoder role in
  let rec feed = function
    | [] -> failwith "missing head"
    | chunk :: rest -> (
        let n, result =
          ok (H.feed_head decoder chunk ~off:0 ~len:(String.length chunk))
        in
        require (n = String.length chunk);
        match (result, rest) with
        | Some metadata, [] -> metadata
        | None, _ :: _ -> feed rest
        | _ -> failwith "head completion mismatch")
  in
  feed chunks

let jobs () =
  List.concat_map
    (fun fields ->
      let extra =
        List.init fields (fun i -> ("x-" ^ string_of_int i, "value"))
      in
      List.concat_map
        (fun request ->
          let headers =
            (if request then [ ("host", "x") ] else [])
            @ [ ("content-length", "0") ]
            @ extra
          in
          let start =
            if request then "GET /hello HTTP/1.1\r\n" else "HTTP/1.1 200 OK\r\n"
          in
          let wire =
            start
            ^ String.concat ""
                (List.map (fun (k, v) -> k ^ ": " ^ v ^ "\r\n") headers)
            ^ "\r\n"
          in
          List.concat_map
            (fun step ->
              (* All implementations receive the same pre-fragmented strings. Buffer
           allocation/copying inside each API remains part of the measurement. *)
              let chunks = fragments step wire in
              let run_kit () =
                let m =
                  kit
                    (if request then H.Request else H.Response Method.get)
                    chunks
                in
                require (m.framing = H.Fixed 0L);
                match m.head with
                | H.Request_head r ->
                    require
                      (request
                      && Method.equal (Request.meth r) Method.get
                      && Target.to_string (Request.target r) = "/hello"
                      && kit_fields (Request.headers r) = headers)
                | H.Response_head r ->
                    require
                      ((not request)
                      && Response.status r = Status.ok
                      && kit_fields (Response.headers r) = headers)
              in
              (* The pinned raw http/af parser passes wire-order fields to an
                 internally reversed header representation. Expected order is
                 prepared outside timing; all names here are unique. *)
              let httpaf_expected = List.rev headers in
              let run_httpaf () =
                let actual =
                  if request then (
                    let r =
                      angstrom Httpaf.Httpaf_private.Parse.request chunks
                    in
                    require
                      (r.meth = `GET && r.target = "/hello"
                     && r.version.major = 1 && r.version.minor = 1);
                    Httpaf.Headers.to_list r.headers)
                  else
                    let r =
                      angstrom Httpaf.Httpaf_private.Parse.response chunks
                    in
                    require
                      (r.status = `OK && r.version.major = 1
                     && r.version.minor = 1);
                    Httpaf.Headers.to_list r.headers
                in
                check_fields actual httpaf_expected
              in
              let run_httpun () =
                let actual =
                  if request then (
                    let r =
                      angstrom Httpun.Httpun_private.Parse.request chunks
                    in
                    require
                      (r.meth = `GET && r.target = "/hello"
                     && r.version.major = 1 && r.version.minor = 1);
                    Httpun.Headers.to_list r.headers)
                  else
                    let r =
                      angstrom Httpun.Httpun_private.Parse.response chunks
                    in
                    require
                      (r.status = `OK && r.version.major = 1
                     && r.version.minor = 1);
                    Httpun.Headers.to_list r.headers
                in
                check_fields actual headers
              in
              let comparison =
                Printf.sprintf "head/%s/fields-%d/step-%d"
                  (if request then "request" else "response")
                  fields step
              in
              List.map
                (fun (implementation, work) ->
                  job ~bytes:(String.length wire) ~comparison ~implementation
                    "http1"
                    ("external/" ^ comparison ^ "/" ^ implementation)
                    200 work)
                [
                  ("http-kit", run_kit);
                  ("httpaf", run_httpaf);
                  ("httpun", run_httpun);
                ])
            [ 1; 64; 16384 ])
        [ true; false ])
    [ 0; 10; 90 ]
