open Httpkit_core
module W = Httpkit

let mime path =
  match String.lowercase_ascii (Filename.extension path) with
  | ".html" -> "text/html; charset=utf-8"
  | ".css" -> "text/css; charset=utf-8"
  | ".js" -> "text/javascript; charset=utf-8"
  | ".json" -> "application/json"
  | ".txt" -> "text/plain; charset=utf-8"
  | ".png" -> "image/png"
  | ".jpg" | ".jpeg" -> "image/jpeg"
  | ".gif" -> "image/gif"
  | ".svg" -> "image/svg+xml"
  | ".ico" -> "image/x-icon"
  | ".pdf" -> "application/pdf"
  | ".woff2" -> "font/woff2"
  | _ -> "application/octet-stream"

let static ?(max_bytes = 8388608) ?(cache_control = "public, max-age=60") ~root
    url request =
  if max_bytes < 0 then invalid_arg "static limit";
  let meth = Request.meth (App.head request) in
  if meth <> Method.get && meth <> Method.head then
    App.reply (W.Reply.make ~status:405 ~headers:[ ("allow", "GET, HEAD") ] "")
  else
    match W.Url.path_segments url with
    | Error _ -> App.reply (W.Reply.text ~status:400 "Invalid file path\n")
    | Ok segments
      when List.exists
             (fun s -> s = "" || String.starts_with ~prefix:"." s)
             segments ->
        App.reply (W.Reply.text ~status:404 "Not found\n")
    | Ok segments -> (
        try
          Eio.Path.with_subtree root (fun root ->
              let path = Eio.Path.(root / String.concat "/" segments) in
              Eio.Path.with_open_in path (fun flow ->
                  let stat = Eio.File.stat flow in
                  if
                    stat.kind <> `Regular_file
                    || stat.size > Optint.Int63.of_int max_bytes
                  then App.reply (W.Reply.text ~status:404 "Not found\n")
                  else
                    let b = Buffer.create (min max_bytes 8192)
                    and bytes = Cstruct.create 8192 in
                    let rec collect () =
                      match Eio.Flow.single_read flow bytes with
                      | n ->
                          if n > max_bytes - Buffer.length b then raise Exit;
                          Buffer.add_string b (Cstruct.to_string ~len:n bytes);
                          collect ()
                      | exception End_of_file -> Buffer.contents b
                    in
                    let data = collect () in
                    let etag =
                      "\""
                      ^ Digestif.SHA256.(to_hex (digest_string data))
                      ^ "\""
                    in
                    let candidates =
                      W.Reply.header_values "if-none-match"
                        (Request.headers (App.head request))
                      |> List.concat_map (String.split_on_char ',')
                      |> List.map String.trim
                    in
                    let matches =
                      List.exists
                        (fun tag ->
                          tag = "*" || tag = etag || tag = "W/" ^ etag)
                        candidates
                    in
                    let headers =
                      [
                        ("etag", etag);
                        ("cache-control", cache_control);
                        ("x-content-type-options", "nosniff");
                      ]
                    in
                    if matches then
                      App.reply (W.Reply.make ~status:304 ~headers "")
                    else
                      App.reply
                        (W.Reply.make
                           ~headers:(("content-type", mime url) :: headers)
                           data)))
        with Eio.Io _ | Exit ->
          App.reply (W.Reply.text ~status:404 "Not found\n"))

let with_upload ~directory ~random request ~boundary callback =
  Eio.Path.with_subtree directory (fun root ->
      Eio.Switch.run (fun sw ->
          let current = ref None and paths = ref [] in
          let close_current () =
            match !current with
            | None -> ()
            | Some (_, _, flow) ->
                current := None;
                Eio.Flow.close flow
          in
          Fun.protect
            ~finally:(fun () ->
              Eio.Cancel.protect (fun () ->
                  Fun.protect
                    ~finally:(fun () ->
                      List.iter
                        (fun path -> Eio.Path.unlink ~missing_ok:true path)
                        !paths)
                    close_current))
            (fun () ->
              let parser =
                W.Multipart.create ~boundary (function
                  | W.Multipart.Begin part ->
                      let entropy = random 24 in
                      if String.length entropy <> 24 then
                        invalid_arg "upload entropy";
                      let name =
                        Base64.encode_string ~pad:false
                          ~alphabet:Base64.uri_safe_alphabet entropy
                      in
                      let path = Eio.Path.(root / name) in
                      let flow =
                        Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) path
                      in
                      paths := path :: !paths;
                      current := Some (part, name, flow)
                  | W.Multipart.Data s -> (
                      match !current with
                      | Some (_, _, flow) -> Eio.Flow.copy_string s flow
                      | None -> failwith "upload part missing")
                  | W.Multipart.End -> (
                      match !current with
                      | Some (part, name, _) ->
                          close_current ();
                          callback part name
                      | None -> failwith "upload part missing"))
              in
              match App.multipart request parser with
              | Ok () -> ()
              | Error e -> invalid_arg e)))
