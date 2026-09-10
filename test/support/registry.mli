type requirement = {
  id : string;
  rule : string;
  layer : string;
  source : string;
  cases : string list;
  implemented : bool;
}

val requirements : requirement list
val pending_capabilities : string list
val to_json : unit -> Yojson.Safe.t
