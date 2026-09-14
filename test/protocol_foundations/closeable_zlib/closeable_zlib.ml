(*---------------------------------------------------------------------------
   Copyright (c) 2024 The bytesrw programmers. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

open Bytesrw

(* [Zbuf.t] values are used to communicate buffers with C. For better
   or worse we use the same data structure that zstd uses. The
   conversion to libz's model occurs in the bindings on the C side *)

module Zbuf = struct
  type t = {
    (* keep in sync with ocaml_zbuf_fields enum in C stub *)
    mutable bytes : Bytes.t;
    mutable size : int; (* last read or write position + 1 *)
    mutable pos : int; (* next read or write position *)
  }

  let make_empty () = { bytes = Bytes.empty; size = 0; pos = 0 }

  let make size =
    { bytes = Bytes.create (Bytes.Slice.check_length size); size; pos = 0 }

  let src_is_consumed buf = buf.pos >= buf.size
  let src_rem buf = buf.size - buf.pos

  let src_set_slice buf s =
    buf.bytes <- Bytes.Slice.bytes s;
    buf.size <- Bytes.Slice.first s + Bytes.Slice.length s;
    buf.pos <- Bytes.Slice.first s

  let src_to_slice_or_eod buf =
    let src_rem = src_rem buf in
    if src_rem = 0 then Bytes.Slice.eod
    else Bytes.Slice.make buf.bytes ~first:buf.pos ~length:src_rem

  let dst_clear buf = buf.pos <- 0
  let dst_is_empty buf = buf.pos = 0
  let dst_is_full buf = buf.pos = buf.size
  let dst_to_slice buf = Bytes.Slice.make buf.bytes ~first:0 ~length:buf.pos
end

(* Errors. Stubs raise [Failure] in case of error which we turn into
   Bytes.Stream.Error with the following error. *)

type Bytes.Stream.error += Error of string

let format_error ~format =
  let case msg = Error msg in
  let message = function Error msg -> msg | _ -> assert false in
  Bytes.Stream.make_format_error ~format ~case ~message

(* Library parameters *)

let default_slice_length = 131072 (* 128KB, our choice not zlib's one *)

(* Decompression *)

type z_stream_inflate
(* Custom value holding a z_stream. We manually
  deallocate them when we know but they have a finalizer which if not NULL
  yet calls inflateEnd and frees the pointer *)

external create_inflate_z_stream : window_bits:int -> z_stream_inflate
  = "ocaml_bytesrw_create_inflate_z_stream"

external free_inflate_z_stream : z_stream_inflate -> unit
  = "ocaml_bytesrw_free_inflate_z_stream"

external inflate : z_stream_inflate -> src:Zbuf.t -> dst:Zbuf.t -> bool
  = "ocaml_bytesrw_inflate"

external inflate_reset : z_stream_inflate -> unit
  = "ocaml_bytesrw_inflate_reset"

let make_z_stream_inflate ~error ~window_bits =
  match create_inflate_z_stream ~window_bits with
  | exception Failure e -> error e
  | zs -> zs

type decompress_eos_action = Parse_eod | Next | Stop

type decompress_state =
  | Await
  | Eod
  | Eos of { leftover : Bytes.Slice.t }
  | Flush

let err_unexp_eod error = error ?pos:None "Unexpected end of compressed data"

let err_exp_eod ~leftover error =
  error ?pos:(Some (-Bytes.Slice.length leftover)) "Expected end of data"

let inflate_reads ~error ~reader_error ~eos_action ~window_bits () ?pos
    ?(slice_length = default_slice_length) r =
  let src = Zbuf.make_empty () and dst = Zbuf.make slice_length in
  let zs = make_z_stream_inflate ~error ~window_bits in
  let error ?pos = reader_error r ?pos in
  let state = ref Await in
  let active = ref false in
  let close () =
    state := Eod;
    free_inflate_z_stream zs
  in
  (* The following invariant must hold. [free_inflate_z_stream] is only ever
     called after [state] becomes [Eod]. This state is sticky and any
     read in this state returns [Bytes.Slice.eod]. *)
  let rec decompress ~error zs ~src ~dst =
    match inflate zs ~src ~dst with
    | exception Failure e ->
        close ();
        error ?pos:None e
    | eos ->
        state :=
          begin if eos then Eos { leftover = Zbuf.src_to_slice_or_eod src }
          else if (not (Zbuf.src_is_consumed src)) || Zbuf.dst_is_full dst then
            Flush
          else Await
          end;
        if Zbuf.dst_is_empty dst then read ()
        else
          let slice = Zbuf.dst_to_slice dst in
          Zbuf.dst_clear dst;
          slice
  and await ~error r zs ~src ~dst =
    let slice = Bytes.Reader.read r in
    if !state = Eod then Bytes.Slice.eod
    else if Bytes.Slice.is_eod slice then (
      close ();
      err_unexp_eod error)
    else (
      Zbuf.src_set_slice src slice;
      decompress ~error zs ~src ~dst)
  and eos_next ~error ~leftover r zs ~src ~dst =
    let slice =
      match Bytes.Slice.is_eod leftover with
      | true -> Bytes.Reader.read r
      | false -> leftover
    in
    if !state = Eod then Bytes.Slice.eod
    else if Bytes.Slice.is_eod slice then (
      close ();
      Bytes.Slice.eod)
    else
      match inflate_reset zs with
      | () ->
          Zbuf.src_set_slice src slice;
          decompress ~error zs ~src ~dst
      | exception Failure e ->
          close ();
          error ?pos:None e
  and eos_parse_eod ~error ~leftover r zs =
    close ();
    if not (Bytes.Slice.is_eod leftover) then err_exp_eod ~leftover error
    else
      let s = Bytes.Reader.read r in
      if Bytes.Slice.is_eod s then s else err_exp_eod ~leftover:s error
  and eos_stop ~leftover r zs =
    close ();
    Bytes.Reader.push_back r leftover;
    Bytes.Slice.eod
  and read () =
    match !state with
    | Await -> await ~error r zs ~src ~dst
    | Flush -> decompress ~error zs ~src ~dst
    | Eos { leftover } ->
        begin match eos_action with
        | Next -> eos_next ~error ~leftover r zs ~src ~dst
        | Parse_eod -> eos_parse_eod ~error ~leftover r zs
        | Stop -> eos_stop ~leftover r zs
        end
    | Eod -> Bytes.Slice.eod
  in
  let guarded_read () =
    if !active then invalid_arg "closeable gzip: concurrent read";
    active := true;
    Fun.protect
      ~finally:(fun () -> active := false)
      (fun () ->
        try read ()
        with exn ->
          let bt = Printexc.get_raw_backtrace () in
          close ();
          Printexc.raise_with_backtrace exn bt)
  in
  try (Bytes.Reader.make ?pos ~slice_length guarded_read, close)
  with exn ->
    let bt = Printexc.get_raw_backtrace () in
    close ();
    Printexc.raise_with_backtrace exn bt

let gzip ?(all_members = true) ?slice_length source =
  let format = format_error ~format:"gzip" in
  inflate_reads
    ~error:(Bytes.Stream.error format)
    ~reader_error:(Bytes.Reader.error format)
    ~eos_action:(if all_members then Next else Stop)
    ~window_bits:31 () ?slice_length source
