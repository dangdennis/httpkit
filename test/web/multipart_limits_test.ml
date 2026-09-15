module M = Httpkit.Multipart
module S = Segmentation_support

let field = "Content-Disposition: form-data; name=\"x\""

let wire ?(header = field) payload =
  "--b\r\n" ^ header ^ "\r\n\r\n" ^ payload ^ "\r\n--b--\r\n"

let check_case ?header label payload make expected =
  let input = wire ?header payload in
  List.iter
    (fun (schedule, cuts) ->
      let data = Buffer.create 4 and starts = ref 0 and ends = ref 0 in
      let parser =
        make (function
          | M.Begin _ -> incr starts
          | M.Data bytes -> Buffer.add_string data bytes
          | M.End -> incr ends)
      in
      let window = S.window cuts (String.length input) in
      let rec feed pos =
        if pos = String.length input then M.finish parser
        else
          let n = window pos in
          match M.feed parser (String.sub input pos n) with
          | Error _ as e -> e
          | Ok () -> feed (pos + n)
      in
      let result = feed 0 in
      S.check (Result.is_ok result = expected) (label ^ "/" ^ schedule);
      if expected then
        S.check
          (!starts = 1 && !ends = 1 && Buffer.contents data = payload)
          (label ^ " event/body mismatch")
      else (
        S.check (M.retained_bytes parser = 0) (label ^ " retained failure input");
        S.check
          (Result.is_error (M.feed parser input)
          && Result.is_error (M.finish parser))
          (label ^ " terminal failure")))
    (S.schedules (String.length input))

let limits () =
  List.iter
    (fun max_header_bytes ->
      check_case
        ("header=" ^ string_of_int max_header_bytes)
        "data"
        (M.create ~boundary:"b" ~max_header_bytes)
        true)
    [ String.length field; max_int - 3; max_int - 2; max_int - 1; max_int ];
  check_case "header one over" "data"
    (M.create ~boundary:"b" ~max_header_bytes:(String.length field - 1))
    false;
  check_case "part exact" "data" (M.create ~boundary:"b" ~max_part_bytes:4) true;
  check_case "part one over" "data"
    (M.create ~boundary:"b" ~max_part_bytes:3)
    false;
  check_case "empty part" "" (M.create ~boundary:"b" ~max_part_bytes:0) true;
  check_case "part count exact" "data"
    (M.create ~boundary:"b" ~max_parts:1)
    true;
  check_case "part count zero" "data"
    (M.create ~boundary:"b" ~max_parts:0)
    false;
  check_case "total exact" "data"
    (M.create ~boundary:"b" ~max_total_bytes:(String.length (wire "data")))
    true;
  check_case "total one over" "data"
    (M.create ~boundary:"b" ~max_total_bytes:(String.length (wire "data") - 1))
    false

let header_controls () =
  let check_header label header expected =
    let make emit =
      M.create ~boundary:"b" (fun event ->
          if not expected then
            S.check false (label ^ ": invalid header emitted a part");
          emit event)
    in
    check_case ~header label "data" make expected
  in
  List.iter
    (fun whitespace ->
      check_header "legal OWS"
        ("Content-Disposition:" ^ whitespace ^ "form-data; name=x" ^ whitespace)
        true)
    [ ""; " "; "\t"; " \t " ];
  List.iter
    (fun n ->
      let c = String.make 1 (Char.chr n) in
      List.iter
        (fun value ->
          check_header
            ("control " ^ string_of_int n)
            ("Content-Disposition:" ^ value)
            false)
        [ c ^ "form-data; name=x"; "form-data; name=x" ^ c ];
      check_header "extension header control"
        (field ^ "\r\nX-Metadata:" ^ c ^ "value")
        false)
    (List.filter (( <> ) 9) (List.init 32 Fun.id) @ [ 127 ])

let boundary_controls () =
  List.iter
    (fun n ->
      let c = String.make 1 (Char.chr n) in
      List.iter
        (fun value ->
          S.check
            (Result.is_error (M.boundary value))
            ("content-type control accepted: " ^ string_of_int n))
        [
          c ^ "multipart/form-data; boundary=b";
          "multipart/form-data; boundary=b" ^ c;
          "multipart/form-data; ignored=" ^ c ^ "x; boundary=b";
        ])
    (List.filter (( <> ) 9) (List.init 32 Fun.id) @ [ 127 ])

let () =
  Alcotest.run "multipart limit boundaries"
    [
      ( "limits",
        [
          Alcotest.test_case "segmented exact and overflow limits" `Quick limits;
          Alcotest.test_case "header controls and OWS across segmentation"
            `Quick header_controls;
          Alcotest.test_case "content-type controls" `Quick boundary_controls;
        ] );
    ]
