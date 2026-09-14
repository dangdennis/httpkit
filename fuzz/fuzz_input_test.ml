exception Property_failure

let expect_failure f =
  match f () with
  | () -> failwith "Expected the original property failure"
  | exception Property_failure -> ()

let expect_invalid f =
  match f () with
  | _ -> failwith "Invalid replay input accepted"
  | exception Invalid_argument _ -> ()

let () =
  let directory = Filename.temp_file "httpkit-fuzz-input-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat directory name))
        (Sys.readdir directory);
      Unix.rmdir directory)
    (fun () ->
      let path name = Filename.concat directory name in
      let input = path "replay" and capture = path "capture" in
      let bytes = "GET / HTTP/1.1\r\nX: \000\255\r\n\r\n" in
      Fuzz_input.save input bytes;
      Unix.putenv "HTTP_KIT_FUZZ_INPUT" input;
      Unix.putenv "HTTP_KIT_FUZZ_CAPTURE" capture;
      let called = ref false in
      Fuzz_input.add ~name:"raw replay" (fun actual ->
          assert (actual = bytes);
          called := true);
      assert !called;
      assert (not (Sys.file_exists capture));
      expect_failure (fun () ->
          Fuzz_input.add ~name:"failure" (fun actual ->
              assert (actual = bytes);
              raise Property_failure));
      assert (Fuzz_input.read capture = bytes);
      assert ((Unix.stat capture).st_perm land 0o077 = 0);
      expect_failure (fun () ->
          Fuzz_input.protect (fun _ -> raise Property_failure) "replacement");
      assert (Fuzz_input.read capture = bytes);
      Unix.putenv "HTTP_KIT_FUZZ_CAPTURE" (path "missing/capture");
      expect_failure (fun () ->
          Fuzz_input.protect (fun _ -> raise Property_failure) bytes);
      Fuzz_input.save (path "maximum") (String.make 65536 '\000');
      assert (String.length (Fuzz_input.read (path "maximum")) = 65536);
      Fuzz_input.save (path "oversized") (String.make 65537 'x');
      expect_invalid (fun () -> Fuzz_input.read (path "oversized"));
      Unix.mkfifo (path "fifo") 0o600;
      expect_invalid (fun () -> Fuzz_input.read (path "fifo"));
      expect_invalid (fun () -> Fuzz_input.read directory));
  print_endline "PASS raw replay and failure preservation controls"
