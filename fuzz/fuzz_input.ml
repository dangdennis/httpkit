let read path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let stat = Unix.fstat fd in
      if stat.st_kind <> Unix.S_REG then
        invalid_arg "raw fuzz input must be a regular file";
      let length = stat.st_size in
      if length > 65536 then invalid_arg "raw fuzz input exceeds 64 KiB";
      let data = Bytes.create (length + 1) in
      let rec loop offset =
        if offset > length then invalid_arg "raw fuzz input grew while reading";
        match Unix.read fd data offset (Bytes.length data - offset) with
        | 0 -> Bytes.sub_string data 0 offset
        | count -> loop (offset + count)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
      in
      loop 0)

let save path data =
  let fd =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
  in
  let channel = Unix.out_channel_of_descr fd in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel data)

let protect f data =
  try f data
  with exn ->
    let trace = Printexc.get_raw_backtrace () in
    (match Sys.getenv_opt "HTTP_KIT_FUZZ_FAILURE" with
    | None -> ()
    | Some path -> (
        try
          let stack = Printexc.raw_backtrace_to_string trace in
          if stack = "" then invalid_arg "failure stack unavailable";
          let fingerprint = Printexc.exn_slot_name exn ^ "\n" ^ stack in
          if String.length fingerprint > 65536 then
            invalid_arg "failure stack exceeds 64 KiB";
          save path fingerprint
        with _ -> ()));
    (match Sys.getenv_opt "HTTP_KIT_FUZZ_CAPTURE" with
    | None -> ()
    | Some path -> (
        try save path data
        with capture_error -> (
          try
            Printf.eprintf "Failure input capture failed: %s\n%!"
              (Printexc.to_string capture_error)
          with _ -> ())));
    Printexc.raise_with_backtrace exn trace

type counts = {
  mutable generated : int;
  mutable checked : int;
  mutable skipped : int;
  mutable failed : int;
  mutable maximum_input_bytes : int;
  mutable maximum_checked_input_bytes : int;
}

let counts () =
  {
    generated = 0;
    checked = 0;
    skipped = 0;
    failed = 0;
    maximum_input_bytes = 0;
    maximum_checked_input_bytes = 0;
  }

let encode_counts t =
  Printf.sprintf
    "{\"schema\":1,\"generated\":%d,\"checked\":%d,\"skipped\":%d,\"failed\":%d,\"maximum_input_bytes\":%d,\"maximum_checked_input_bytes\":%d}\n"
    t.generated t.checked t.skipped t.failed t.maximum_input_bytes
    t.maximum_checked_input_bytes

let run t ~max_length f data =
  t.generated <- t.generated + 1;
  t.maximum_input_bytes <- max t.maximum_input_bytes (String.length data);
  if String.length data > max_length then (
    t.skipped <- t.skipped + 1;
    false)
  else
    match protect f data with
    | () ->
        t.checked <- t.checked + 1;
        t.maximum_checked_input_bytes <-
          max t.maximum_checked_input_bytes (String.length data);
        true
    | exception exn ->
        let trace = Printexc.get_raw_backtrace () in
        t.failed <- t.failed + 1;
        Printexc.raise_with_backtrace exn trace

let totals = counts ()
let registered = ref false

let record ~max_length f data =
  (* Register during the first callback: Crowbar starts its tests from an exit
     hook. An earlier registration would flush zero counts before tests run. *)
  if not !registered then (
    registered := true;
    Option.iter
      (fun path -> at_exit (fun () -> save path (encode_counts totals)))
      (Sys.getenv_opt "HTTP_KIT_FUZZ_STATS"));
  run totals ~max_length f data

let lengths max_length =
  [
    0;
    1;
    63;
    64;
    65;
    125;
    126;
    127;
    255;
    256;
    1023;
    1024;
    2047;
    2048;
    8191;
    8192;
    16383;
    16384;
    65535;
    65536;
    max_length;
    max_length + 1;
  ]
  |> List.filter (fun n -> n <= min 65536 (max_length + 1))
  |> List.sort_uniq Int.compare

let rec fixed_bytes n =
  (* Crowbar's primitive fixed-byte reader has a small refill buffer. Compose
     short independent blocks instead of requesting a whole large input. *)
  if n <= 64 then Crowbar.bytes_fixed n
  else
    let left = n / 2 in
    Crowbar.map [ fixed_bytes left; fixed_bytes (n - left) ] ( ^ )

let generator max_length =
  Crowbar.choose
    [
      Crowbar.bytes; Crowbar.choose (List.map fixed_bytes (lengths max_length));
    ]

let add ?(max_length = 65536) ~name f =
  if max_length < 0 || max_length > 65536 then invalid_arg "fuzz input limit";
  match Sys.getenv_opt "HTTP_KIT_FUZZ_INPUT" with
  | None ->
      Crowbar.add_test ~name
        [ generator max_length ]
        (fun data -> ignore (record ~max_length f data))
  | Some path ->
      if not (record ~max_length f (read path)) then
        invalid_arg "raw fuzz input exceeds target limit";
      Printf.printf "%s: PASS\n%!" name
