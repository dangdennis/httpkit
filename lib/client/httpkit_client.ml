open Httpkit_core

exception Unframed_https_response

let check_response ?(meth = Method.get) ~tls response =
  let status = Status.to_int (Response.status response) in
  let absent name =
    Headers.get_all
      (Result.get_ok (Header.Name.of_string name))
      (Response.headers response)
    = []
  in
  if
    tls
    && (not (Method.equal meth Method.head))
    && status <> 204 && status <> 304 && absent "content-length"
    && absent "transfer-encoding"
  then raise Unframed_https_response

type endpoint = {
  host : string;
  port : int;
  tls : bool;
  request : unit Request.t;
}

let check_timeout seconds =
  if (not (Float.is_finite seconds)) || seconds <= 0. then
    invalid_arg "httpkit client: timeout must be finite and positive"

type framing = [ `Empty | `Fixed of int64 | `Chunked ]

let same_origin a b =
  String.lowercase_ascii a.host = String.lowercase_ascii b.host
  && a.port = b.port && a.tls = b.tls

let prepare ?(headers = Headers.empty) ?(meth = Method.get) ?(body = `Empty)
    ?(keep_alive = false) url =
  let error () =
    Error "httpkit client: invalid HTTP/HTTPS URL or request headers"
  in
  if
    (not
       (List.mem (Method.to_string meth)
          [ "GET"; "HEAD"; "POST"; "PUT"; "PATCH"; "DELETE"; "OPTIONS" ]))
    || (Method.equal meth Method.head && body <> `Empty)
    || (match body with `Fixed n -> n < 0L | _ -> false)
    || String.length url > 8192
    || String.exists
         (fun c -> Char.code c <= 32 || Char.code c >= 127 || c = '\\')
         url
  then error ()
  else
    try
      let uri = Uri.of_string url in
      let scheme = Uri.scheme uri in
      (* Uri normalizes an empty port away. Preserve the codec's strict
         authority policy before using the parsed fields. *)
      let start = String.index url ':' + 3 in
      let stop = ref start in
      while
        !stop < String.length url
        && not (List.mem url.[!stop] [ '/'; '?'; '#' ])
      do
        incr stop
      done;
      let authority = String.sub url start (!stop - start) in
      if
        (not (List.mem scheme [ Some "http"; Some "https" ]))
        || Uri.userinfo uri <> None
        || Uri.fragment uri <> None
        || String.ends_with ~suffix:":" authority
        || String.contains authority '%'
      then error ()
      else
        match Uri.host uri with
        | None | Some "" -> error ()
        | Some host -> (
            let tls = scheme = Some "https" in
            let port =
              Option.value (Uri.port uri) ~default:(if tls then 443 else 80)
            in
            if port <= 0 || port > 65535 then error ()
            else
              let reserved =
                [
                  "host";
                  "connection";
                  "content-length";
                  "transfer-encoding";
                  "trailer";
                  "te";
                  "upgrade";
                  "expect";
                ]
              in
              let fields =
                List.map
                  (fun h ->
                    ( Header.Name.to_string (Header.name h),
                      Header.Value.to_string (Header.value h) ))
                  (Headers.to_list headers)
              in
              if
                List.exists
                  (fun (name, _) ->
                    List.mem (String.lowercase_ascii name) reserved)
                  fields
              then error ()
              else
                let authority =
                  (if String.contains host ':' then "[" ^ host ^ "]" else host)
                  ^
                  if (tls && port = 443) || ((not tls) && port = 80) then ""
                  else ":" ^ string_of_int port
                in
                let path = if Uri.path uri = "" then "/" else Uri.path uri in
                let target =
                  path
                  ^
                  match Uri.verbatim_query uri with
                  | None -> ""
                  | Some q -> "?" ^ q
                in
                match
                  ( Target.of_string target,
                    Headers.of_list
                      (("host", authority)
                       ::
                       (if keep_alive then [] else [ ("connection", "close") ])
                      @ (match body with
                        | `Empty -> []
                        | `Fixed n -> [ ("content-length", Int64.to_string n) ]
                        | `Chunked -> [ ("transfer-encoding", "chunked") ])
                      @ fields) )
                with
                | Ok target, Ok headers -> (
                    let request = Request.create ~meth ~target ~headers () in
                    match Httpkit_http1.encode_request request with
                    | Ok _ -> Ok { host; port; tls; request }
                    | Error _ -> error ())
                | _ -> error ())
    with Invalid_argument _ | Failure _ | Not_found -> error ()

exception Tls_truncated
