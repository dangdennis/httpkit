(** Materialized, bounded scripts for a synthetic stream subject. No HTTP
    parsing. *)
type role = Client | Server

type config = {
  incoming_limit : int;
  outgoing_limit : int;
  header_deadline_ns : int64;
  max_steps : int;
}

type action =
  | Open of int
  | Begin of int * int * int
  | Input of int * string
  | Consume of int * int
  | Send of int * int * string
  | Write of int * int
  | Finish of int
  | Wait_body of int
  | Cancel of int
  | Eof of int
  | Read_error of int
  | Write_error of int
  | Shutdown of int
  | Run of int * int
  | Advance of int64

type t = {
  id : string;
  role : role;
  seed : string;
  config : config;
  actions : action list;
}

val default_config : config
val validate : t -> (unit, string) result
val to_json : t -> Yojson.Safe.t
val of_string : string -> (t, string) result
val load : string -> (t, string) result
val save : string -> t -> unit
val action_to_json : action -> Yojson.Safe.t
val connection : action -> int option
val max_encoded_bytes : int
