open Http_kit_core
open Suite_support

let jobs () =
  List.concat_map
    (fun size ->
      let path = "/" ^ String.make (size - 1) 'a' in
      let invalid = String.sub path 0 (size - 1) ^ "\r" in
      [
        job ~bytes:size "core" (Printf.sprintf "target/valid/%d" size) 2000
          (fun () ->
            require (Target.to_string (ok (Target.of_string path)) = path));
        job ~bytes:size "core" (Printf.sprintf "target/reject-last/%d" size)
          2000 (fun () -> require (Result.is_error (Target.of_string invalid)));
      ])
    [ 16; 256; 8192 ]
  @ List.concat_map
      (fun size ->
        let fields = List.init size (fun _ -> ("x", "value")) in
        let headers = ok (Headers.of_list ~max_fields:101 fields) in
        let field = ok (Header.of_strings "x" "value") in
        let name = ok (Header.Name.of_string "x") in
        [
          job "core" (Printf.sprintf "headers/construct/%d" size) 1000
            (fun () ->
              require (Headers.length (ok (Headers.of_list fields)) = size));
          job "core" (Printf.sprintf "headers/append/%d" size) 5000 (fun () ->
              require
                (Headers.length (ok (Headers.add field headers)) = size + 1));
          job "core" (Printf.sprintf "headers/get-all/%d" size) 5000 (fun () ->
              require (List.length (Headers.get_all name headers) = size));
        ])
      [ 1; 10; 100 ]
