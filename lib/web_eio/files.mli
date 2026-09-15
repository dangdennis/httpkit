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
    are removed after each callback returns, including exceptional or cancelled
    return, before the next part is processed. Partial files are removed when
    parsing fails or is cancelled. The basename is valid only during its
    callback; copy durable data explicitly. Cleanup I/O errors propagate and may
    replace a callback/parser failure through [Fun.protect]. Permanent unlink
    failure can leave a closed temporary file in [directory]; its owner must
    recover that directory. Cleanup attempts are bounded, not a guarantee that a
    failing filesystem removes the file. Exclusive-create collisions preserve
    pre-existing files. *)
