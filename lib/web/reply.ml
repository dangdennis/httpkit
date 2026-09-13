open Httpkit_core

let checked = function
  | Ok v -> v
  | Error _ -> invalid_arg "invalid HTTP response metadata"

let header_values name headers =
  Headers.get_all (checked (Header.Name.of_string name)) headers
  |> List.map Header.Value.to_string

let set_header name value response =
  let key = String.lowercase_ascii name in
  let fields =
    Headers.to_list (Response.headers response)
    |> List.filter_map (fun h ->
        let n = Header.Name.to_string (Header.name h) in
        if String.lowercase_ascii n = key then None
        else Some (n, Header.Value.to_string (Header.value h)))
  in
  Response.with_headers
    (checked (Headers.of_list (fields @ [ (name, value) ])))
    response

let make ?(status = 200) ?(headers = []) body =
  if status < 200 || status > 599 then invalid_arg "final response status";
  if (status = 204 || status = 205 || status = 304) && body <> "" then
    invalid_arg "body forbidden for status";
  if
    List.exists
      (fun (n, _) ->
        List.mem (String.lowercase_ascii n)
          [ "content-length"; "transfer-encoding" ])
      headers
  then invalid_arg "framing is owned by Reply";
  let headers =
    if status = 204 || status = 304 then headers
    else headers @ [ ("content-length", string_of_int (String.length body)) ]
  in
  Response.create
    ~status:(checked (Status.of_int status))
    ~headers:(checked (Headers.of_list headers))
    body

let text ?status body =
  make ?status ~headers:[ ("content-type", "text/plain; charset=utf-8") ] body

let html ?status body =
  make ?status ~headers:[ ("content-type", "text/html; charset=utf-8") ] body

let json ?status body =
  make ?status
    ~headers:[ ("content-type", "application/json") ]
    (Yojson.Safe.to_string ~std:true body)

let redirect ?(status = 303) target =
  if not (List.mem status [ 301; 302; 303; 307; 308 ]) then
    invalid_arg "redirect status";
  if
    target = ""
    || target.[0] <> '/'
    || (String.length target > 1 && target.[1] = '/')
    || String.contains target '\\'
  then invalid_arg "redirect requires a local absolute path";
  make ~status ~headers:[ ("location", target) ] ""
