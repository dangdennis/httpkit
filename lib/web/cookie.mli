type same_site = Strict | Lax | None_

val parse :
  ?max_bytes:int ->
  ?max_cookies:int ->
  string list ->
  ((string * string) list, string) result
(** Preserves duplicates; use [find] to reject ambiguous credentials. *)

val find : string -> (string * string) list -> (string option, string) result

val set :
  ?secure:bool ->
  ?http_only:bool ->
  ?same_site:same_site ->
  ?path:string ->
  ?max_age:int ->
  string ->
  string ->
  string
(** Host-only cookies; Secure, HttpOnly, SameSite=Lax, Path=/ by default. *)
