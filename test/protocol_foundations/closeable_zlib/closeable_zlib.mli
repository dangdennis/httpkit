(** Private ownership experiment derived from Bytesrw 0.4.0. Uses its pinned
    private C ABI; not a supported wrapper or a production library. *)
val gzip :
  ?all_members:bool ->
  ?slice_length:int ->
  Bytesrw.Bytes.Reader.t ->
  Bytesrw.Bytes.Reader.t * (unit -> unit)
(** Returns a reader and an idempotent close operation. Close never reads the
    source, and later reads return end-of-data. Exceptions from the source close
    the native decoder and preserve the original exception/backtrace. Confined
    to one domain; overlapping reads are rejected. Close may run while a source
    callback is suspended; its returned slice is then discarded. *)
