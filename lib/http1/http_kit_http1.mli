open Http_kit_core
(** Strict HTTP/1.1 codecs. No I/O, clock, scheduler, or implicit input reads.
    Decoder instances have one owner. Expected failures are values and terminal.
*)

type error =
  | Invalid_slice
  | Invalid_state
  | Invalid_line
  | Invalid_field
  | Unsupported_version
  | Invalid_target
  | Invalid_host
  | Ambiguous_framing
  | Invalid_length
  | Unsupported_coding
  | Unsupported_expectation
  | Invalid_chunk
  | Invalid_trailer
  | Limit_exceeded
  | Unexpected_eof

val error_to_string : error -> string

type limits

val limits :
  ?line:int ->
  ?headers:int ->
  ?fields:int ->
  ?trailers:int ->
  ?trailer_fields:int ->
  ?chunk_line:int ->
  ?step:int ->
  ?body:int64 ->
  unit ->
  (limits, error) result
(** Defaults: 8192-byte start/field lines, 32768-byte head, 100 fields,
    16384-byte trailers, 64 trailer fields, 1024-byte chunk line, 16384-byte
    per-call input/data budget. Optional total body quota. Negative/zero
    byte/work budgets fail; field counts and body quota may be zero. *)

val default_limits : limits

val step_limit : limits -> int
(** Maximum input bytes and emitted data bytes per codec operation. *)

type framing = Empty | Fixed of int64 | Chunked | Close_delimited | Tunnel
type head = Request_head of unit Request.t | Response_head of unit Response.t

type metadata = private {
  head : head;
  framing : framing;
  persistent : bool;
  expect_continue : bool;
  trailer_names : Header.Name.t list;
}

type role = Request | Response of Method.t
type head_decoder

val head_decoder : ?limits:limits -> role -> head_decoder

val feed_head :
  head_decoder ->
  string ->
  off:int ->
  len:int ->
  (int * metadata option, error) result
(** Consumes at most [step] bytes, stopping exactly after CRLFCRLF. The caller
    owns every unconsumed suffix. No metadata is exposed before validation. Byte scanning
    is linear in accepted bytes. Connection/trailer membership uses a balanced
    set: O((C + T) log(C + 1)) name comparisons for C connection and T trailer
    tokens; each comparison is bounded by the name length. Retained head memory
    is O(header bytes). *)

val eof_head : head_decoder -> (unit, error) result
(** A partial or absent head at EOF fails; an already completed head succeeds.
*)

val encode_request :
  ?limits:limits -> 'a Request.t -> (string * metadata, error) result

val encode_response :
  ?limits:limits ->
  request_method:Method.t ->
  'a Response.t ->
  (string * metadata, error) result
(** Validate all metadata before returning any bytes. Reason phrases are empty.
    HTTP/1.0 is explicitly unsupported. No framing headers are inferred. *)

type body_event = Data of string | Trailers of Headers.t | End
type body_decoder

val body_decoder : ?limits:limits -> metadata -> body_decoder

val feed_body :
  body_decoder ->
  string ->
  off:int ->
  len:int ->
  (int * body_event option, error) result
(** Emits at most one event per call. Data is copied into an owned immutable
    string of at most [step] bytes. Empty input is not EOF. After the last data
    event, call again (even with empty input) to receive End exactly once.
    Trailer fields must be declared and must not be security/framing fields. *)

val eof_body : body_decoder -> (body_event option, error) result
(** Close-delimited bodies finish at EOF; incomplete fixed/chunked bodies fail.
    Tunnel bytes are never consumed by this codec. *)

type body_encoder

val body_encoder : ?limits:limits -> metadata -> body_encoder

val encode_data : body_encoder -> string -> (string, error) result
(** Empty data is a no-op, not end. Each supplied chunk is bounded by [step]. A
    failed operation makes the encoder terminal. *)

val finish_body : ?trailers:Headers.t -> body_encoder -> (string, error) result
(** Checks exact fixed length and trailer policy. Must be called once. *)
