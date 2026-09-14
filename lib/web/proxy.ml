type ip_header = Forwarded_for | Real_ip
type t = { scheme : string; client_ip : string }

let resolve ?(ip_header = Forwarded_for) ~trusted_peer ~peer headers =
  if not (trusted_peer peer) then Ok None
  else
    let ip_name =
      match ip_header with
      | Forwarded_for -> "x-forwarded-for"
      | Real_ip -> "x-real-ip"
    in
    match
      ( Reply.header_values "x-forwarded-proto" headers,
        Reply.header_values ip_name headers,
        Reply.header_values "forwarded" headers )
    with
    | [ scheme ], [ client_ip ], [] when List.mem scheme [ "http"; "https" ]
      -> (
        match Ipaddr.of_string client_ip with
        | Ok _ -> Ok (Some { scheme; client_ip })
        | Error _ -> Error "invalid forwarded IP")
    | _ -> Error "ambiguous forwarding metadata"
