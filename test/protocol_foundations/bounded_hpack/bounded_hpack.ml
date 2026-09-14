type header = Types.header = { name : string; value : string; sensitive : bool }
type limits = { max_wire : int; max_fields : int; max_bytes : int }
type t = { decoder : Decoder.t; limits : limits; mutable failed : bool }

let create ~table_capacity limits =
  if
    table_capacity < 0 || table_capacity > 65536 || limits.max_wire < 0
    || limits.max_fields < 0 || limits.max_bytes < 0
    || limits.max_bytes > max_int / 4
  then invalid_arg "HPACK limits";
  { decoder = Decoder.create table_capacity; limits; failed = false }

let decode t wire =
  if t.failed then Error "decoder is terminal; close connection"
  else (
    t.failed <- true;
    if String.length wire > t.limits.max_wire then Error "HPACK wire budget"
    else
      match
        Angstrom.parse_string ~consume:All
          (Decoder.decode_headers ~max_fields:t.limits.max_fields
             ~max_bytes:t.limits.max_bytes t.decoder)
          wire
      with
      | Ok (Ok headers) ->
          t.failed <- false;
          Ok headers
      | Ok (Error _) -> Error "HPACK decoding error"
      | Error reason -> Error reason)
