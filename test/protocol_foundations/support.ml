let require condition message = if not condition then failwith message
let ok = function Ok x -> x | Error (`Msg message) -> failwith message

let read path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let fragments size data f =
  let rec loop off =
    if off < String.length data then (
      let len = min size (String.length data - off) in
      f (String.sub data off len);
      loop (off + len))
  in
  loop 0

let allocated f =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  let result = f () in
  (result, Gc.allocated_bytes () -. before)
