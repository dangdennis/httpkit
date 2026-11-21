open Httpkit_core
module E = Httpkit_engine
module A = Httpkit_transport_eio

let ok = Result.get_ok
let input = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"

let response =
  Response.create ~status:Status.ok
    ~headers:(ok (Headers.of_list [ ("content-length", "3") ]))
    ()

let expected = "HTTP/1.1 200 \r\ncontent-length: 3\r\n\r\nabc"

let controls bytes =
  let at i = if String.length bytes <= i then 0 else Char.code bytes.[i] in
  (1 + (at 0 mod 32), 1 + (at 1 mod 16), at 2 mod 2 = 1, 1 + (at 3 mod 4))

let check closed active out cancelled =
  Crowbar.check (!closed = 1 && !active = 0);
  let out = Buffer.contents out in
  Crowbar.check
    (if cancelled then String.starts_with ~prefix:out expected
     else out = expected)

let eio bytes =
  Eio_mock.Backend.run_full (fun env ->
      let fragment, step, cancelled, block_at = controls bytes in
      let offset = ref 0
      and writes = ref 0
      and closed = ref 0
      and active = ref 0
      and out = Buffer.create 64 in
      let started, resolver = Eio.Promise.create () in
      let transport : A.transport =
        {
          read =
            (fun dst off len ->
              let n = min fragment (min len (String.length input - !offset)) in
              Bytes.blit_string input !offset dst off n;
              offset := !offset + n;
              n);
          write =
            (fun src off len ->
              incr writes;
              if cancelled && !writes = block_at then (
                incr active;
                Eio.Promise.resolve resolver ();
                Fun.protect
                  ~finally:(fun () -> decr active)
                  Eio.Fiber.await_cancel)
              else
                let n = min step len in
                Buffer.add_substring out src off n;
                n);
          close = (fun () -> incr closed);
        }
      in
      let run () =
        A.with_connection
          ~clock:(Eio.Stdenv.mono_clock env)
          transport
          (ok (E.server ()))
          (fun c ->
            let id =
              match A.next_event c with
              | E.Request (id, _) -> id
              | _ -> assert false
            in
            assert (A.next_event c = E.Complete id);
            A.respond c id response;
            A.send c id "abc";
            A.finish c id)
      in
      (try
         if cancelled then
           Eio.Fiber.first run (fun () ->
               Eio.Promise.await started;
               raise Exit)
         else run ()
       with Exit -> Crowbar.check cancelled);
      check closed active out cancelled)

let () =
  Fuzz_input.add ~max_length:1024
    ~name:"native adapter partial I/O and cancellation" eio
