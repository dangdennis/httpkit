open Httpkit_core
module W = Httpkit

type access = {
  request_id : string;
  meth : string;
  path : string;
  status : int;
  seconds : float;
}

let access_log ~now log next request =
  let start = now () in
  let response = next request in
  let head = App.head request in
  let target = Target.to_string (Request.target head) in
  let path = List.hd (String.split_on_char '?' target) in
  log
    {
      request_id = App.request_id request;
      meth = Method.to_string (Request.meth head);
      path;
      status = App.status response;
      seconds = max 0. (now () -. start);
    };
  response

let set name value =
  App.map_headers (fun headers ->
      Response.headers
        (W.Reply.set_header name value
           (Response.create ~status:Status.ok ~headers ())))

let security_headers next request =
  next request
  |> set "x-content-type-options" "nosniff"
  |> set "referrer-policy" "no-referrer"
  |> set "x-frame-options" "DENY"

let vary fields response =
  App.map_headers
    (fun headers ->
      let current =
        W.Reply.header_values "vary" headers
        |> List.concat_map (String.split_on_char ',')
        |> List.map String.trim
      in
      let all =
        List.fold_left
          (fun acc x ->
            if
              List.exists
                (fun y -> String.lowercase_ascii x = String.lowercase_ascii y)
                acc
            then acc
            else acc @ [ x ])
          current fields
      in
      Response.headers
        (W.Reply.set_header "vary" (String.concat ", " all)
           (Response.create ~status:Status.ok ~headers ())))
    response

let cors ~origins ~methods ~headers ?(credentials = false) () =
  if
    List.exists
      (fun o ->
        o = "*" || o = "null" || o = ""
        || String.exists (fun c -> Char.code c <= 32) o)
      origins
  then invalid_arg "CORS exact origins required";
  List.iter (fun m -> ignore (Result.get_ok (Method.of_string m))) methods;
  List.iter (fun h -> ignore (Result.get_ok (Header.Name.of_string h))) headers;
  let allowed_headers = List.map String.lowercase_ascii headers in
  fun next request ->
    let h = Request.headers (App.head request) in
    let response =
      match W.Reply.header_values "origin" h with
      | [] -> next request
      | [ origin ] when List.mem origin origins ->
          let preflight =
            Request.meth (App.head request) = Method.options
            && W.Reply.header_values "access-control-request-method" h <> []
          in
          let result =
            if preflight then
              match
                ( W.Reply.header_values "access-control-request-method" h,
                  W.Reply.header_values "access-control-request-headers" h )
              with
              | [ meth ], hs when List.mem meth methods && List.length hs <= 1
                ->
                  let requested =
                    List.concat_map (String.split_on_char ',') hs
                    |> List.map (fun s ->
                        String.lowercase_ascii (String.trim s))
                  in
                  if
                    List.for_all (fun s -> List.mem s allowed_headers) requested
                  then
                    App.reply
                      (W.Reply.make ~status:204
                         ~headers:
                           [
                             ( "access-control-allow-methods",
                               String.concat ", " methods );
                             ( "access-control-allow-headers",
                               String.concat ", " headers );
                           ]
                         "")
                  else App.reply (W.Reply.text ~status:403 "CORS denied\n")
              | _ -> App.reply (W.Reply.text ~status:403 "CORS denied\n")
            else next request
          in
          let result = set "access-control-allow-origin" origin result in
          if credentials then
            set "access-control-allow-credentials" "true" result
          else result
      | _ -> App.reply (W.Reply.text ~status:403 "CORS denied\n")
    in
    vary
      [
        "Origin";
        "Access-Control-Request-Method";
        "Access-Control-Request-Headers";
      ]
      response

type proxy = W.Proxy.t = { scheme : string; client_ip : string }

let proxy ?ip_header ~trusted_peer request =
  W.Proxy.resolve ?ip_header ~trusted_peer ~peer:(App.peer request)
    (Request.headers (App.head request))
