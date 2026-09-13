open Httpkit_core

let check condition message = if not condition then failwith message
let ok = function Ok x -> x | Error e -> failwith (Error.to_string e)

let rejects reason = function
  | Error e -> check (e.Error.reason = reason) (Error.to_string e)
  | Ok _ -> failwith "accepted invalid value"

let token_chars =
  "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

let uri_chars =
  "!$&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]_abcdefghijklmnopqrstuvwxyz~"

let exhaustive predicate constructor =
  for n = 0 to 255 do
    let c = Char.chr n in
    check
      (Result.is_ok (constructor c) = predicate c)
      (Printf.sprintf "byte %d" n)
  done

let cases =
  [
    ( "core/method-alphabet",
      fun () ->
        exhaustive (String.contains token_chars) (fun c ->
            Method.of_string (String.make 1 c)) );
    ( "core/name-alphabet",
      fun () ->
        exhaustive (String.contains token_chars) (fun c ->
            Header.Name.of_string (String.make 1 c)) );
    ( "core/value-alphabet",
      fun () ->
        exhaustive
          (fun c -> c = '\t' || (Char.code c >= 32 && Char.code c <> 127))
          (fun c -> Header.Value.of_string ("a" ^ String.make 1 c ^ "b")) );
    ( "core/target-alphabet",
      fun () ->
        exhaustive (String.contains uri_chars) (fun c ->
            Target.of_string ("/" ^ String.make 1 c)) );
    ( "core/case-and-duplicates",
      fun () ->
        check
          (not (Method.equal Method.get (ok (Method.of_string "get"))))
          "method case folded";
        let headers =
          ok
            (Headers.of_list
               [ ("Set-Cookie", "a=1"); ("x", "v"); ("SET-cookie", "b=2") ])
        in
        let name = ok (Header.Name.of_string "sEt-CoOkIe") in
        check
          (List.map Header.Value.to_string (Headers.get_all name headers)
          = [ "a=1"; "b=2" ])
          "duplicates merged/reordered";
        check
          (List.map
             (fun h -> Header.Name.to_string (Header.name h))
             (Headers.to_list headers)
          = [ "set-cookie"; "x"; "set-cookie" ])
          "field order lost" );
    ( "core/injection",
      fun () ->
        List.iter
          (fun s -> rejects Error.Invalid_byte (Header.Value.of_string s))
          [ "x\r\nX-Evil: yes"; "x\000y"; "x\127y"; "x\ny"; "x\ry" ];
        List.iter
          (fun s -> rejects Error.Invalid_byte (Target.of_string s))
          [ "/ HTTP/1.1\r\n"; "/#fragment"; "/\\evil"; "/\255" ];
        rejects Error.Invalid_byte (Header.Name.of_string "x:y") );
    ( "core/value-ows",
      fun () ->
        List.iter
          (fun s ->
            rejects Error.Surrounding_whitespace (Header.Value.of_string s))
          [ " "; "\t"; " a"; "a "; "\ta"; "a\t" ];
        ignore (ok (Header.Value.of_string ""));
        ignore (ok (Header.Value.of_string "a \t b")) );
    ( "core/target-escapes",
      fun () ->
        List.iter
          (fun s -> rejects Error.Invalid_escape (Target.of_string s))
          [ "%"; "/%0"; "%GG"; "%0/"; "%00%" ];
        List.iter
          (fun s ->
            check
              (Target.to_string (ok (Target.of_string s)) = s)
              "target normalized")
          [
            "/a%2Fb%00%0d%0A";
            "http://example.test/a?x=1";
            "*";
            "example.test:443";
            "/a/../b";
          ] );
    ( "core/scalar-limits",
      fun () ->
        let test limit make =
          ignore (ok (make (String.make limit 'a')));
          rejects Error.Too_long (make (String.make (limit + 1) 'a'))
        in
        test 64 Method.of_string;
        test 256 Header.Name.of_string;
        test 8192 Header.Value.of_string;
        test 8192 Target.of_string;
        rejects Error.Empty (Method.of_string "");
        rejects Error.Empty (Header.Name.of_string "");
        rejects Error.Empty (Target.of_string "");
        rejects Error.Invalid_limit (Method.of_string ~max_length:(-1) "x");
        rejects Error.Invalid_limit (Header.Name.of_string ~max_length:(-1) "x");
        rejects Error.Invalid_limit (Header.Value.of_string ~max_length:(-1) "");
        rejects Error.Invalid_limit (Target.of_string ~max_length:(-1) "x");
        ignore (ok (Header.Value.of_string ~max_length:0 ""));
        ignore (ok (Method.of_string ~max_length:max_int "x")) );
    ( "core/header-budgets",
      fun () ->
        let field = ok (Header.of_strings "x" "y") in
        let initial = ok (Headers.create ~max_fields:1 ~max_bytes:6 ()) in
        let full = ok (Headers.add field initial) in
        check
          (Headers.wire_bytes full = 6 && Headers.length full = 1)
          "wrong accounting";
        check (Headers.length initial = 0) "collection mutated";
        rejects Error.Too_many_fields (Headers.add field full);
        rejects Error.Too_long
          (Headers.add field (ok (Headers.create ~max_bytes:5 ())));
        rejects Error.Too_many_fields
          (Headers.add field (ok (Headers.create ~max_fields:0 ())));
        rejects Error.Too_long
          (Headers.add field (ok (Headers.create ~max_bytes:0 ())));
        rejects Error.Invalid_limit (Headers.create ~max_bytes:(-1) ());
        rejects Error.Invalid_limit (Headers.create ~max_fields:(-1) ());
        ignore
          (ok
             (Headers.add field
                (ok (Headers.create ~max_fields:max_int ~max_bytes:max_int ()))))
    );
    ( "core/default-field-limit",
      fun () ->
        let fields = List.init 100 (fun _ -> ("x", "")) in
        check
          (Headers.length (ok (Headers.of_list fields)) = 100)
          "premature field rejection";
        rejects Error.Too_many_fields (Headers.of_list (("x", "") :: fields)) );
    ( "core/status-range",
      fun () ->
        for n = -100 to 700 do
          check
            (Result.is_ok (Status.of_int n) = (n >= 100 && n <= 599))
            "wrong status range"
        done;
        rejects Error.Out_of_range (Status.of_int min_int);
        rejects Error.Out_of_range (Status.of_int max_int);
        check (Status.to_int (ok (Status.of_int 471)) = 471) "extension lost" );
    ( "core/body-polymorphism",
      fun () ->
        let body = ref 0 in
        let request =
          Request.create ~meth:Method.post
            ~target:(ok (Target.of_string "/"))
            body
        in
        check (Request.body request == body) "body copied";
        let calls = ref 0 in
        let mapped =
          Request.map_body
            (fun _ ->
              incr calls;
              "bytes")
            request
        in
        check
          (!calls = 1
          && Request.body mapped = "bytes"
          && !(Request.body request) = 0)
          "map contract";
        check
          (Request.meth mapped = Method.post
          && Request.version mapped = Version.Http_1_1)
          "metadata changed";
        let response = Response.create ~status:Status.ok body in
        let mapped =
          Response.map_body
            (fun _ ->
              incr calls;
              ())
            response
        in
        check
          (!calls = 2
          && Response.status mapped = Status.ok
          && Response.body response == body)
          "response map";
        let headers = ok (Headers.of_list [ ("x", "y") ]) in
        check
          (Headers.length
             (Request.headers (Request.with_headers headers request))
          = 1)
          "request header update";
        check
          (Headers.length
             (Response.headers (Response.with_headers headers response))
          = 1)
          "response header update" );
    ( "core/bounded-errors",
      fun () ->
        match Header.Value.of_string "secret\r" with
        | Ok _ -> failwith "accepted CR"
        | Error e ->
            check (e.offset = Some 6) "bad byte offset";
            check
              (Error.to_string e = "header value: invalid byte at byte 6")
              "input leaked" );
  ]

let properties ~seed ~count =
  let open QCheck2 in
  let run name gen property =
    ( name,
      fun () ->
        Test.check_exn
          ~rand:(Random.State.make [| seed |])
          (Test.make ~count ~name gen property) )
  in
  [
    run "core/property-method"
      (Gen.string_size (Gen.int_bound 100))
      (fun s ->
        let expected =
          s <> ""
          && String.length s <= 64
          && String.for_all (String.contains token_chars) s
        in
        match Method.of_string s with
        | Ok m -> expected && Method.to_string m = s
        | Error _ -> not expected);
    run "core/property-header-order"
      (Gen.list_size (Gen.int_bound 100) (Gen.int_bound 10000))
      (fun values ->
        let fields = List.map (fun n -> ("X", string_of_int n)) values in
        let headers = ok (Headers.of_list fields) in
        List.map Header.Value.to_string
          (Headers.get_all (ok (Header.Name.of_string "x")) headers)
        = List.map string_of_int values);
    run "core/property-target-stable"
      (Gen.string_size (Gen.int_bound 100))
      (fun s ->
        match Target.of_string s with
        | Error _ -> true
        | Ok target ->
            Target.to_string target = s
            && String.for_all
                 (fun c -> String.contains uri_chars c || c = '%')
                 s);
    run "core/property-value"
      (Gen.string_size (Gen.int_bound 100))
      (fun s ->
        let codes = List.init (String.length s) (fun i -> Char.code s.[i]) in
        let edge n = n <> 32 && n <> 9 in
        let expected =
          List.for_all (fun n -> n = 9 || (n >= 32 && n <> 127)) codes
          && (s = ""
             || edge (Char.code s.[0])
                && edge (Char.code s.[String.length s - 1]))
        in
        match Header.Value.of_string s with
        | Ok value -> expected && Header.Value.to_string value = s
        | Error _ -> not expected);
  ]
