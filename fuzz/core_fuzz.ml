open Http_kit_core

let token_chars =
  "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

let () =
  Crowbar.add_test ~name:"core lexical constructors" [ Crowbar.bytes ]
    (fun bytes ->
      let method_valid =
        bytes <> ""
        && String.length bytes <= 64
        && String.for_all (String.contains token_chars) bytes
      in
      (match Method.of_string bytes with
      | Error _ -> Crowbar.check (not method_valid)
      | Ok method_ ->
          Crowbar.check (method_valid && Method.to_string method_ = bytes));
      let value_valid =
        String.length bytes <= 8192
        && String.for_all
             (fun c -> c = '\t' || (Char.code c >= 32 && Char.code c <> 127))
             bytes
        && (bytes = ""
           ||
           let edge c = c <> ' ' && c <> '\t' in
           edge bytes.[0] && edge bytes.[String.length bytes - 1])
      in
      (match Header.Value.of_string bytes with
      | Error _ -> Crowbar.check (not value_valid)
      | Ok value ->
          Crowbar.check (value_valid && Header.Value.to_string value = bytes));
      match Target.of_string bytes with
      | Error _ -> ()
      | Ok target ->
          Crowbar.check (Target.to_string target = bytes);
          Crowbar.check (Target.of_string (Target.to_string target) = Ok target))
