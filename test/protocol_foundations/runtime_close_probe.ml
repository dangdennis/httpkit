open Support
module B = Bytesrw.Bytes

let run () =
  let eio_closed = ref false in
  Eio_main.run (fun _ ->
      let entered, signal = Eio.Promise.create () in
      let never, _ = Eio.Promise.create () in
      let reader, close =
        Closeable_zlib.gzip
          (B.Reader.make (fun () ->
               Eio.Promise.resolve signal ();
               Eio.Promise.await never))
      in
      Eio.Fiber.first
        (fun () ->
          Fun.protect
            ~finally:(fun () ->
              close ();
              eio_closed := true)
            (fun () -> ignore (B.Reader.read reader)))
        (fun () -> Eio.Promise.await entered);
      require !eio_closed "Eio cancellation skipped close";
      require (B.Slice.is_eod (B.Reader.read reader)) "Eio reader not closed");
  let consumer_closed = ref false in
  let wire = Bytes.of_string (read "fixtures/payload.gz") in
  let pulled = ref false in
  let source =
    B.Reader.make (fun () ->
        if !pulled then B.Slice.eod
        else (
          pulled := true;
          B.Slice.make wire ~first:0 ~length:(Bytes.length wire)))
  in
  let reader, close = Closeable_zlib.gzip ~slice_length:128 source in
  Eio_main.run (fun _ ->
      let suspended, signal = Eio.Promise.create () in
      let never, _ = Eio.Promise.create () in
      Eio.Fiber.first
        (fun () ->
          Fun.protect
            ~finally:(fun () ->
              close ();
              consumer_closed := true)
            (fun () ->
              require
                (B.Slice.length (B.Reader.read reader) = 128)
                "Eio consumer initial data";
              Eio.Promise.resolve signal ();
              Eio.Promise.await never))
        (fun () -> Eio.Promise.await suspended));
  require !consumer_closed "Eio consumer cancellation skipped close";
  require
    (B.Slice.is_eod (B.Reader.read reader))
    "Eio consumer reader not closed";
  `Assoc
    [
      ("eio_source_cancellation", `String "PASS");
      ("eio_consumer_cancellation", `String "PASS");
      ("production_ready", `Bool false);
    ]
