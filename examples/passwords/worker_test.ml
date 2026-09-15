module Worker = Password_example_worker.Worker

let check label value = if not value then failwith label

let () =
  Eio_main.run (fun env ->
      let escaped = ref None in
      Eio.Switch.run (fun sw ->
          let worker = Worker.create ~sw (Eio.Stdenv.domain_mgr env) in
          escaped := Some worker;
          let started, notify_started = Eio.Promise.create () in
          let release, notify_release = Eio.Promise.create () in
          let cancelled, notify_cancelled = Eio.Promise.create () in
          let context, notify_context = Eio.Promise.create () in
          let done_ = ref false in
          let main_domain = Domain.self () in
          Eio.Fiber.both
            (fun () ->
              Fun.protect
                ~finally:(fun () -> done_ := true)
                (fun () ->
                  match
                    Eio.Cancel.sub (fun cc ->
                        Eio.Promise.resolve notify_context cc;
                        Worker.run worker (fun () ->
                            check "job runs in a separate domain"
                              (Domain.self () <> main_domain);
                            Eio.Promise.resolve notify_started ();
                            Eio.Promise.await release;
                            42))
                  with
                  | _ -> failwith "cancelled job delivered its result"
                  | exception Eio.Cancel.Cancelled _ -> ()))
            (fun () ->
              let cc = Eio.Promise.await context in
              Eio.Promise.await started;
              check "excess job rejected without running"
                (Worker.run worker (fun () -> failwith "excess job ran")
                = Error `Busy);
              Eio.Cancel.cancel cc Exit;
              Eio.Promise.resolve notify_cancelled ();
              Eio.Fiber.yield ();
              check "cancelled caller still owns job" (not !done_);
              check "cancelled work still occupies admission"
                (Worker.run worker (fun () -> failwith "early admission")
                = Error `Busy);
              Eio.Promise.resolve notify_release ());
          Eio.Promise.await cancelled;
          check "caller joined" !done_;
          check "slot reused after completion"
            (Worker.run worker (fun () -> 7) = Ok 7);
          (match Worker.run worker (fun () -> raise Exit) with
          | _ -> failwith "worker exception swallowed"
          | exception Exit -> ());
          check "slot reused after exception"
            (Worker.run worker (fun () -> 8) = Ok 8);
          let policy =
            Httpkit_password.create ~memory_kib:19456 ~iterations:2 ()
          in
          let encoded =
            match
              Worker.run worker (fun () ->
                  Httpkit_password.hash policy
                    ~random:(fun n -> String.make n 's')
                    "synthetic test password")
            with
            | Ok (Ok encoded) -> encoded
            | _ -> failwith "native hash failed"
          in
          check "native verification on worker"
            (Worker.run worker (fun () ->
                 Httpkit_password.verify policy ~encoded
                   "synthetic test password")
            = Ok (Ok true)));
      match Worker.run (Option.get !escaped) ignore with
      | _ -> failwith "worker escaped owning switch"
      | exception Invalid_argument _ -> ());
  print_endline
    "PASS password worker admission, cancellation join, exceptions and native \
     roundtrip"
