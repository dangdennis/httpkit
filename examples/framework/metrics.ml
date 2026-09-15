module A = Httpkit_transport_eio
module E = Httpkit_engine
module W = Httpkit

type t = {
  mutable opened : int;
  mutable closed : int;
  mutable peak : int;
  mutable expected : int;
  mutable unexpected : int;
}

let create () =
  { opened = 0; closed = 0; peak = 0; expected = 0; unexpected = 0 }

let transport t (transport : A.transport) =
  t.opened <- t.opened + 1;
  t.peak <- max t.peak (t.opened - t.closed);
  {
    transport with
    close =
      (fun () ->
        Fun.protect
          ~finally:(fun () -> t.closed <- t.closed + 1)
          transport.close);
  }

let rec error t = function
  | Eio.Exn.Multiple errors -> List.iter (fun (exn, _) -> error t exn) errors
  | A.Error (A.Timeout _ | A.Engine (E.Protocol _ | E.Resource_limit))
  | A.Error (A.Transport (Eio.Io _))
  | Eio.Time.Timeout | End_of_file ->
      t.expected <- t.expected + 1
  | Httpkit_eio.Realtime.Protocol_error _ -> t.expected <- t.expected + 1
  | Failure message when message = "example error" ->
      t.expected <- t.expected + 1
  | _ -> t.unexpected <- t.unexpected + 1

let snapshot t =
  Gc.full_major ();
  let gc = Gc.stat () in
  `Assoc
    [
      ("opened", `Int t.opened);
      ("closed", `Int t.closed);
      ("active", `Int (t.opened - t.closed));
      ("peak_active", `Int t.peak);
      ("expected_errors", `Int t.expected);
      ("unexpected_errors", `Int t.unexpected);
      ("live_words", `Int gc.live_words);
      ("heap_words", `Int gc.heap_words);
    ]

(* Sampling does not force GC; process counters include the small sampling cost. *)
let counters ~max_connections () =
  let gc = Gc.quick_stat () and cpu = Unix.times () in
  `Assoc
    [
      ("ocaml_version", `String Sys.ocaml_version);
      ("runtime", `String "eio");
      ("max_connections", `Int max_connections);
      ( "allocated_words",
        `Float (gc.minor_words +. gc.major_words -. gc.promoted_words) );
      ("word_bytes", `Int (Sys.word_size / 8));
      ("minor_collections", `Int gc.minor_collections);
      ("major_collections", `Int gc.major_collections);
      ("cpu_seconds", `Float (cpu.tms_utime +. cpu.tms_stime));
    ]
