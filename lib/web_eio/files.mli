val static :
  ?max_bytes:int ->
  ?cache_control:string ->
  root:_ Eio.Path.t ->
  string ->
  App.handler
(** Serves a decoded relative URL under a freshly confined subtree. No directory
    listings or ranges. Files are collected up to [max_bytes] for consistent
    ETags. *)

val with_upload :
  directory:_ Eio.Path.t ->
  random:(int -> string) ->
  App.request ->
  boundary:string ->
  (Httpkit.Multipart.part -> string -> unit) ->
  unit
(** Calls back with each completed file's generated basename. Temporary files
    are removed on callback return, error, or cancellation. Copy durable data
    explicitly. *)
