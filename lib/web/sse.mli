val event :
  ?id:string ->
  ?event:string ->
  ?retry:int ->
  ?max_bytes:int ->
  string ->
  (string, string) result

val comment : string -> (string, string) result
(** Producers must be bounded; the Eio streaming response supplies backpressure.
*)
