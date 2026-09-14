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
  let lwt_closed = ref false in
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
  let pending, _ = Lwt.task () in
  let consumer =
    Lwt.finalize
      (fun () ->
        require (B.Slice.length (B.Reader.read reader) = 128) "Lwt initial data";
        pending)
      (fun () ->
        close ();
        lwt_closed := true;
        Lwt.return_unit)
  in
  Lwt.cancel consumer;
  Lwt_main.run
    (Lwt.catch
       (fun () -> consumer)
       (function Lwt.Canceled -> Lwt.return_unit | exn -> Lwt.fail exn));
  require !lwt_closed "Lwt cancellation skipped close";
  require (B.Slice.is_eod (B.Reader.read reader)) "Lwt reader not closed";
  `Assoc
    [
      ("eio_source_cancellation", `String "PASS");
      ("lwt_consumer_cancellation", `String "PASS");
      ("production_ready", `Bool false);
    ]
