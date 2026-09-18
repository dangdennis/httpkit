open Common

(* Opt-in diagnostics, never acceptance timings. A separate process must watch
   the snapshot timestamp: this sampler cannot run if the runtime itself stalls. *)
type worker = { state : (string * float) Atomic.t; completed : int Atomic.t }

let phase worker name =
  Option.iter (fun w -> Atomic.set w.state (name, monotonic ())) worker

let completed worker = Option.iter (fun w -> Atomic.incr w.completed) worker

let with_workers path count f =
  match path with
  | None -> f (Array.make count None)
  | Some path -> (
      let workers =
        Array.init count (fun _ ->
            {
              state = Atomic.make ("starting", monotonic ());
              completed = Atomic.make 0;
            })
      in
      let snapshot status =
        let now = monotonic () in
        let rows =
          Array.mapi
            (fun index w ->
              let phase, since = Atomic.get w.state in
              `Assoc
                [
                  ("worker", `Int index);
                  ("phase", `String phase);
                  ("phase_seconds", `Float (now -. since));
                  ("completed", `Int (Atomic.get w.completed));
                ])
            workers
        in
        save (path ^ ".tmp")
          (`Assoc
             [
               ("pid", `Int (Unix.getpid ()));
               ("status", `String status);
               ("monotonic", `Float now);
               ("workers", `List (Array.to_list rows));
             ]);
        Unix.rename (path ^ ".tmp") path
      in
      snapshot "running";
      let stopped = Atomic.make false and error = Atomic.make None in
      let sampler =
        Thread.create
          (fun () ->
            try
              while not (Atomic.get stopped) do
                Unix.sleepf 0.5;
                if not (Atomic.get stopped) then snapshot "running"
              done
            with exn -> Atomic.set error (Some exn))
          ()
      in
      let outcome =
        try Ok (f (Array.map Option.some workers)) with exn -> Error exn
      in
      Atomic.set stopped true;
      Thread.join sampler;
      snapshot (match outcome with Ok _ -> "complete" | Error _ -> "failed");
      match outcome with
      | Error exn -> raise exn
      | Ok value ->
          Option.iter raise (Atomic.get error);
          value)
