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

let add ~name f =
  match Sys.getenv_opt "HTTP_KIT_FUZZ_INPUT" with
  | None -> Crowbar.add_test ~name [ Crowbar.bytes ] (protect f)
  | Some path ->
      protect f (read path);
      Printf.printf "%s: PASS\n%!" name
