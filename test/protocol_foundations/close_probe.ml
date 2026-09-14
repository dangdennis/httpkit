open Support
module B = Bytesrw.Bytes

exception Cancelled of int

let run () =
  let calls = ref 0 in
  let source () =
    B.Reader.make (fun () ->
        incr calls;
        failwith "closed reader pulled input")
  in
  let reader, close = Closeable_zlib.gzip (source ()) in
  close ();
  close ();
  require (B.Slice.is_eod (B.Reader.read reader)) "read after close";
  require (!calls = 0) "close must not drain source";
  let sentinel = Cancelled 42 in
  let reader, close =
    Closeable_zlib.gzip (B.Reader.make (fun () -> raise sentinel))
  in
  (try
     ignore (B.Reader.read reader);
     failwith "missing source exception"
   with Cancelled _ as exn -> require (exn == sentinel) "exception identity");
  require (B.Slice.is_eod (B.Reader.read reader)) "exception did not close";
  close ();
  (* Simulate a callback that resumes after another fiber closes the decoder. *)
  let close_ref = ref Fun.id in
  let wire = Bytes.of_string (read "fixtures/payload.gz") in
  let reader, close =
    Closeable_zlib.gzip
      (B.Reader.make (fun () ->
           !close_ref ();
           B.Slice.make wire ~first:0 ~length:(Bytes.length wire)))
  in
  close_ref := close;
  require
    (B.Slice.is_eod (B.Reader.read reader))
    "resumed source used closed state";
  let reader_ref = ref None in
  let reader, close =
    Closeable_zlib.gzip
      (B.Reader.make (fun () ->
           match !reader_ref with
           | None -> failwith "reader not initialized"
           | Some reader -> B.Reader.read reader))
  in
  reader_ref := Some reader;
  (try
     ignore (B.Reader.read reader);
     failwith "overlapping read accepted"
   with Invalid_argument reason ->
     require
       (reason = "closeable gzip: concurrent read")
       "wrong overlap failure");
  require (B.Slice.is_eod (B.Reader.read reader)) "overlap failure not terminal";
  close ();
  (* Retain closed readers across a collection: stale handles must stay inert. *)
  let readers =
    Array.init 2000 (fun _ ->
        let reader, close = Closeable_zlib.gzip (source ()) in
        close ();
        (reader, close))
  in
  Gc.full_major ();
  Array.iter
    (fun (reader, close) ->
      close ();
      require (B.Slice.is_eod (B.Reader.read reader)) "retained closed reader")
    readers;
  require (!calls = 0) "retained readers drained source";
  let controls =
    Zlib_probe.run
      ~reader_factory:(fun ~slice_length source ->
        Closeable_zlib.gzip ~slice_length source)
      ()
  in
  `Assoc
    [
      ("status", `String "PASS");
      ("closed_readers_retained", `Int (Array.length readers));
      ("codec_controls", controls);
      ("native_memory_measured", `Bool false);
      ("production_ready", `Bool false);
    ]
