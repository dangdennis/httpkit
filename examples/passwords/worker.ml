type t = {
  pool : Eio.Executor_pool.t;
  mutable busy : bool;
  mutable closed : bool;
}

let create ~sw domain_mgr =
  let pool = Eio.Executor_pool.create ~sw ~domain_count:1 domain_mgr in
  let t = { pool; busy = false; closed = false } in
  Eio.Switch.on_release sw (fun () -> t.closed <- true);
  t

let run t f =
  Eio.Fiber.check ();
  if t.closed then invalid_arg "closed password worker";
  if t.busy then Error `Busy
  else (
    t.busy <- true;
    let result =
      Fun.protect
        ~finally:(fun () -> t.busy <- false)
        (fun () ->
          (* Cancelling the wait cannot interrupt a synchronous native hash.
             Keep admission occupied until its result and cleanup are joined. *)
          Eio.Cancel.protect (fun () ->
              Eio.Executor_pool.submit_exn t.pool ~weight:1. f))
    in
    Eio.Fiber.check ();
    Ok result)
