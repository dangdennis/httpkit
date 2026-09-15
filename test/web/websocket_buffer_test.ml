module W = Httpkit.Websocket
module S = Segmentation_support

let frame ?(fin = true) op data =
  let n = String.length data in
  assert (n < 65536);
  let b = Buffer.create (n + 8) in
  Buffer.add_char b (Char.chr ((if fin then 128 else 0) lor op));
  if n < 126 then Buffer.add_char b (Char.chr (128 lor n))
  else (
    Buffer.add_char b (Char.chr (128 lor 126));
    Buffer.add_char b (Char.chr (n lsr 8));
    Buffer.add_char b (Char.chr (n land 255)));
  let mask = "\x01\x23\x45\x67" in
  Buffer.add_string b mask;
  String.iteri
    (fun i c ->
      Buffer.add_char b (Char.chr (Char.code c lxor Char.code mask.[i mod 4])))
    data;
  Buffer.contents b

let feed t input =
  match W.feed t input with
  | Ok events -> events
  | Error message -> Alcotest.fail message

let chunks input cuts =
  let pos = ref 0 in
  List.map
    (fun stop ->
      let chunk = String.sub input !pos (stop - !pos) in
      pos := stop;
      chunk)
    cuts

let segmented () =
  let input =
    frame ~fin:false 1 "hel" ^ frame 9 "ping" ^ frame 0 "lo" ^ frame 2 "binary"
    ^ frame 8 ""
  in
  List.iter
    (fun (name, cuts) ->
      let t = W.server () in
      let events = List.concat_map (feed t) (chunks input cuts) in
      S.check
        (events
        = [
            W.Ping "ping"; W.Text "hello"; W.Binary "binary"; W.Close (None, "");
          ])
        (name ^ ": coalesced or partial frame lost");
      S.check (W.eof t = Ok ()) (name ^ ": clean close rejected"))
    (S.schedules (String.length input))

let allocated f =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  f ();
  Gc.allocated_bytes () -. before

let scaling label measure small large =
  let a = measure small and b = measure large in
  Printf.eprintf "%s: %d=%.0f bytes; %d=%.0f bytes; ratio=%.2f\n%!" label small
    a large b (b /. a);
  S.check
    (b < (8. *. a) +. 100_000.)
    (label ^ ": fourfold input must not cause quadratic allocation")

let incremental n =
  let data = String.init n (fun i -> Char.chr (i mod 256)) in
  let chunks = frame 2 data |> String.to_seq |> List.of_seq in
  let chunks = List.map (String.make 1) chunks in
  allocated (fun () ->
      let t = W.server () in
      let events = List.concat_map (feed t) chunks in
      S.check (events = [ W.Binary data ]) "one-byte input changed payload")

let coalesced n =
  let input = String.concat "" (List.init n (fun _ -> frame 9 "")) in
  allocated (fun () ->
      let events = feed (W.server ()) input in
      S.check (List.length events = n) "coalesced frame count";
      S.check (List.for_all (( = ) (W.Ping "")) events) "coalesced payload")

let message ~fragmented n =
  let data = String.make n 'x' in
  let input =
    if not fragmented then frame 2 data
    else
      List.init (n / 64) (fun i ->
          frame
            ~fin:(i = (n / 64) - 1)
            (if i = 0 then 2 else 0)
            (String.make 64 'x'))
      |> String.concat ""
  in
  allocated (fun () ->
      S.check
        (feed (W.server ()) input = [ W.Binary data ])
        "complete or fragmented message changed payload")

let () =
  Alcotest.run "websocket buffering"
    [
      ( "semantics",
        [
          Alcotest.test_case "fragment, control and close segmentation" `Quick
            segmented;
        ] );
      ( "allocation",
        [
          Alcotest.test_case "incremental linear growth" `Quick (fun () ->
              scaling "incremental" incremental 4096 16384);
          Alcotest.test_case "coalesced linear growth" `Quick (fun () ->
              scaling "coalesced" coalesced 1024 4096);
          Alcotest.test_case "complete message growth" `Quick (fun () ->
              scaling "complete" (message ~fragmented:false) 4096 16384);
          Alcotest.test_case "fragmented message growth" `Quick (fun () ->
              scaling "fragmented" (message ~fragmented:true) 4096 16384);
        ] );
    ]
