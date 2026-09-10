open Harness
open Scenario

let check condition message = if not condition then failwith message

let pass s =
  let r = Runner.run Contract.Correct s in
  check (r.failure = None) (Yojson.Safe.to_string (Runner.to_json r))

let expect_bad text =
  check
    (Result.is_error (Scenario.of_string text))
    "malformed scenario accepted"

let roundtrip s =
  match Scenario.of_string (Yojson.Safe.to_string (Scenario.to_json s)) with
  | Ok actual -> check (actual = s) "scenario roundtrip mismatch"
  | Error e -> failwith e

let mutate f = Yojson.Safe.to_string (f (Scenario.to_json Fixtures.happy))

let field key value = function
  | `Assoc xs ->
      `Assoc (List.map (fun (k, v) -> (k, if k = key then value else v)) xs)
  | _ -> assert false

let cases =
  List.map
    (fun fault ->
      ( "fault/" ^ Contract.fault_name fault,
        fun () ->
          let s = Fixtures.fault_case fault in
          pass s;
          match (Runner.run fault s).failure with
          | None -> failwith "planted fault escaped"
          | Some f ->
              check
                (f.rule = Fixtures.expected_rule fault)
                ("wrong rule: " ^ f.rule) ))
    Contract.faults
  @ [
      ("model/duplex", fun () -> pass Fixtures.happy);
      ( "model/isolation",
        fun () ->
          pass
            (Fixtures.scenario "ISOLATION"
               [
                 Open 1;
                 Open 0;
                 Begin (1, 7, 1);
                 Begin (0, 7, 1);
                 Input (1, "a");
                 Input (0, "b");
                 Consume (0, 1);
                 Consume (1, 1);
                 Finish 0;
                 Finish 1;
                 Cancel 0;
                 Cancel 1;
               ]) );
      ( "model/backpressure-retry",
        fun () -> pass (Fixtures.fault_case Contract.Double_accept) );
      ( "model/fault-injection",
        fun () ->
          List.iter
            (fun error ->
              pass
                (Fixtures.scenario "IO.ERROR"
                   [ Open 0; Begin (0, 1, 4); Wait_body 0; error; Cancel 0 ]))
            [ Read_error 0; Write_error 0; Eof 0 ] );
      ( "model/deadline-boundary",
        fun () ->
          List.iter
            (fun n ->
              pass
                (Fixtures.scenario "DEADLINE"
                   [ Open 0; Advance n; Input (0, "x") ]))
            [ 9L; 10L; 11L ] );
      ( "model/input-ownership",
        fun () ->
          let module S = (val Fake_subject.make Contract.Correct) in
          let t = S.create default_config in
          ignore (S.step t (Open 0));
          ignore (S.step t (Begin (0, 1, 3)));
          let b = Bytes.of_string "abc" in
          let data = Bytes.to_string b in
          ignore (S.step t (Input (0, data)));
          Bytes.fill b 0 3 'x';
          check
            (S.step t (Consume (0, 3)) = [ (0, Contract.Data (1, "abc")) ])
            "retained caller memory" );
      ( "model/close-cleanup",
        fun () ->
          let r =
            Runner.run Contract.Correct
              (Fixtures.fault_case Contract.Miss_wakeup)
          in
          check (r.failure = None) "cleanup mismatch" );
      ( "replay/100-times",
        fun () ->
          let s = Fixtures.fault_case Contract.Drop_write in
          let serialized = Yojson.Safe.to_string (Scenario.to_json s) in
          let expected = Runner.to_json (Runner.run Contract.Drop_write s) in
          for _ = 1 to 100 do
            match Scenario.of_string serialized with
            | Error e -> failwith e
            | Ok s ->
                check
                  (Runner.to_json (Runner.run Contract.Drop_write s) = expected)
                  "replay differs"
          done );
      ( "replay/fresh-subject",
        fun () ->
          let a = Fixtures.happy
          and b = Fixtures.fault_case Contract.Overbuffer in
          let before = Runner.run Contract.Correct a in
          ignore (Runner.run Contract.Overbuffer b);
          check
            (before = Runner.run Contract.Correct a)
            "cross-run contamination" );
      ( "normalize/boundaries",
        fun () ->
          let open Contract in
          check
            (normalize [ (0, Data (1, "a")); (0, Data (1, "b")) ]
            = [ (0, Data (1, "ab")) ])
            "data normalization";
          check
            (normalize
               [
                 (0, Data (1, "a"));
                 (0, Complete 1);
                 (0, Headers 2);
                 (0, Data (2, "b"));
               ]
            <> normalize [ (0, Data (1, "ab")) ])
            "message boundary erased";
          check
            (normalize [ (0, Data (1, "a")); (1, Data (1, "b")) ]
            <> normalize [ (0, Data (1, "ab")) ])
            "connection boundary erased" );
      ( "shrink/prerequisites",
        fun () ->
          let base = Fixtures.fault_case Contract.Miss_wakeup in
          let s =
            { base with actions = (Open 1 :: base.actions) @ [ Cancel 1 ] }
          in
          let shrunk = Shrink.minimize Contract.Miss_wakeup s in
          check
            (List.length shrunk.scenario.actions < List.length s.actions)
            "did not reduce";
          check
            (Scenario.validate shrunk.scenario = Ok ())
            "deleted prerequisite";
          check
            (Runner.same_failure
               (Runner.run Contract.Miss_wakeup s)
               (Runner.run Contract.Miss_wakeup shrunk.scenario))
            "failure category changed";
          check
            (List.exists
               (function Begin _ -> true | _ -> false)
               shrunk.scenario.actions)
            "deleted begin" );
      ( "shrink/all-faults",
        fun () ->
          List.iter
            (fun f ->
              let s = Fixtures.fault_case f in
              let small = Shrink.minimize f s in
              check (Scenario.validate small.scenario = Ok ()) "invalid shrink";
              check
                (Runner.same_failure (Runner.run f s)
                   (Runner.run f small.scenario))
                "lost failure")
            Contract.faults );
      ( "shrink/budget",
        fun () ->
          let s = Fixtures.fault_case Contract.Drop_write in
          let r = Shrink.minimize ~max_attempts:0 Contract.Drop_write s in
          check (r.exhausted && r.scenario = s) "budget ignored";
          let r =
            Shrink.minimize ~expired:(fun () -> true) Contract.Drop_write s
          in
          check (r.exhausted && r.scenario = s) "deadline ignored" );
      ( "schema/binary-roundtrip",
        fun () ->
          roundtrip
            (Fixtures.scenario "BINARY"
               [ Open 0; Input (0, String.init 256 Char.chr) ]) );
      ( "schema/unknown-version",
        fun () -> expect_bad (mutate (field "schema" (`Int 2))) );
      ( "schema/unknown-key",
        fun () ->
          expect_bad
            (mutate (function
              | `Assoc xs -> `Assoc (("extra", `Null) :: xs)
              | _ -> assert false)) );
      ( "schema/duplicate-key",
        fun () ->
          expect_bad
            (mutate (function
              | `Assoc xs -> `Assoc (("schema", `Int 1) :: xs)
              | _ -> assert false)) );
      ( "schema/unsafe-id",
        fun () -> expect_bad (mutate (field "id" (`String "../../escape"))) );
      ( "schema/bad-base64",
        fun () ->
          expect_bad
            (mutate
               (field "actions"
                  (`List
                     [
                       `Assoc
                         [ ("op", `String "open"); ("connection", `String "0") ];
                       `Assoc
                         [
                           ("op", `String "input");
                           ("connection", `String "0");
                           ("data", `String "!!");
                         ];
                     ]))) );
      ( "schema/depth",
        fun () -> expect_bad (String.make 33 '[' ^ String.make 33 ']') );
      ( "schema/size",
        fun () -> expect_bad (String.make (Scenario.max_encoded_bytes + 1) ' ')
      );
      ( "schema/clock-overflow",
        fun () ->
          let s =
            Fixtures.scenario "OVERFLOW" [ Open 0; Advance Int64.max_int ]
          in
          check (Result.is_error (Scenario.validate s)) "overflow accepted" );
      ( "schema/prerequisite",
        fun () ->
          check
            (Result.is_error
               (Scenario.validate
                  (Fixtures.scenario "INVALID" [ Open 0; Consume (0, 1) ])))
            "missing begin accepted" );
      ( "schema/duplicate-open",
        fun () ->
          check
            (Result.is_error
               (Scenario.validate
                  (Fixtures.scenario "INVALID" [ Open 0; Open 0 ])))
            "duplicate open accepted" );
      ( "schema/deadline-int64",
        fun () ->
          roundtrip
            (Fixtures.scenario
               ~config:
                 { default_config with header_deadline_ns = Int64.max_int }
               "MAX" [ Open 0 ]) );
      ( "schedule/partitions",
        fun () ->
          let parts = Schedule.partitions "abcd" in
          check (List.length parts = 8) "partition count";
          List.iter
            (fun p -> check (String.concat "" p = "abcd") "lost bytes")
            parts;
          check
            (List.length (Schedule.single_splits "abcd") = 5)
            "single splits" );
      ( "schedule/topological",
        fun () ->
          let open Schedule in
          let nodes =
            [
              { id = 0; after = []; action = Open 0 };
              { id = 1; after = [ 0 ]; action = Input (0, "a") };
              { id = 2; after = [ 0 ]; action = Input (0, "b") };
            ]
          in
          (match topological nodes with
          | Ok (xs, false) -> check (List.length xs = 2) "wrong schedule count"
          | _ -> failwith "bad schedules");
          (match topological ~limit:1 nodes with
          | Ok ([ _ ], true) -> ()
          | _ -> failwith "cap not explicit");
          check
            (Result.is_error
               (topological
                  [
                    { id = 0; after = [ 1 ]; action = Open 0 };
                    { id = 1; after = [ 0 ]; action = Open 1 };
                  ]))
            "cycle accepted" );
      ( "runner/step-budget",
        fun () ->
          let s =
            Fixtures.scenario
              ~config:{ default_config with max_steps = 1 }
              "BUDGET"
              [ Open 0; Input (0, "x") ]
          in
          match (Runner.run Contract.Correct s).failure with
          | Some f -> check (f.rule = "WORK.BUDGET") "wrong budget failure"
          | _ -> failwith "budget not enforced" );
      ( "runner/unexpected-exception",
        fun () ->
          let module Bad = struct
            type t = unit

            let create _ = ()
            let step _ _ = failwith "planted"
            let snapshots _ = []
          end in
          match
            (Runner.run_subject
               (module Bad)
               (Fixtures.scenario "EXN" [ Open 0 ]))
              .failure
          with
          | Some f -> check (f.rule = "SUBJECT.EXCEPTION") "exception hidden"
          | _ -> failwith "exception passed" );
      ( "runner/construction-exception",
        fun () ->
          let module Bad = struct
            type t = unit

            let create _ = failwith "construction"
            let step _ _ = []
            let snapshots _ = []
          end in
          match
            (Runner.run_subject
               (module Bad)
               (Fixtures.scenario "EXN" [ Open 0 ]))
              .failure
          with
          | Some f ->
              check
                (f.rule = "SUBJECT.EXCEPTION")
                "construction exception hidden"
          | _ -> failwith "construction passed" );
      ( "watchdog/hang",
        fun () ->
          check
            (Harness_runtime.Watchdog.run ~seconds:0.1 (fun () ->
                 while true do
                   ()
                 done)
            = Harness_runtime.Watchdog.Timed_out)
            "hang escaped" );
      ( "watchdog/failure",
        fun () ->
          check
            (Harness_runtime.Watchdog.run ~seconds:1. (fun () ->
                 failwith "child")
            = Harness_runtime.Watchdog.Exited 1)
            "child failure hidden" );
      ( "watchdog/signal",
        fun () ->
          match
            Harness_runtime.Watchdog.run ~seconds:1. (fun () ->
                Unix.kill (Unix.getpid ()) Sys.sigkill)
          with
          | Harness_runtime.Watchdog.Signaled _ -> ()
          | _ -> failwith "signal hidden" );
      ( "registry/no-fake-http",
        fun () ->
          check
            (List.length Registry.pending_capabilities >= 14)
            "HTTP capabilities disappeared";
          check
            (List.for_all
               (fun r ->
                 (not r.Registry.implemented)
                 || List.mem r.layer
                      [ "harness-self"; "core-values"; "core-install" ])
               Registry.requirements)
            "fake HTTP coverage" );
    ]

let cases =
  cases
  @ [
      ( "registry/linked-cases",
        fun () ->
          List.iter
            (fun requirement ->
              List.iter
                (fun case ->
                  check
                    (List.mem_assoc case cases)
                    ("unknown registry case: " ^ case))
                requirement.Registry.cases)
            (List.filter
               (fun r -> r.Registry.layer = "harness-self")
               Registry.requirements) );
    ]

let properties ~seed ~count =
  let open QCheck2 in
  let run name gen property =
    ( name,
      fun () ->
        Test.check_exn
          ~rand:(Random.State.make [| seed |])
          (Test.make ~name ~count gen property) )
  in
  [
    run "property/scenario-roundtrip" Gen.string_small (fun bytes ->
        let s = Fixtures.scenario "GENERATED" [ Open 0; Input (0, bytes) ] in
        Scenario.of_string (Yojson.Safe.to_string (Scenario.to_json s)) = Ok s);
    run "property/model-agreement"
      Gen.(list_size (int_bound 100) (pair (int_bound 14) string_small))
      (fun operations ->
        let actions =
          Open 0
          :: Begin (0, 1, 10000)
          :: List.map
               (fun (op, s) ->
                 match op with
                 | 0 -> Input (0, s)
                 | 1 -> Consume (0, String.length s mod 12)
                 | 2 -> Send (0, String.length s, s)
                 | 3 -> Write (0, String.length s mod 12)
                 | 4 -> Wait_body 0
                 | 5 -> Finish 0
                 | 6 -> Advance (Int64.of_int (String.length s))
                 | 7 -> Run (0, 1)
                 | 8 -> Eof 0
                 | 9 -> Read_error 0
                 | 10 -> Write_error 0
                 | 11 -> Shutdown 0
                 | 12 -> Begin (0, 2, 0)
                 | 13 -> Cancel 0
                 | _ -> Input (0, ""))
               operations
        in
        (Runner.run Contract.Correct (Fixtures.scenario "GENERATED" actions))
          .failure = None);
    run "property/arbitrary-json" Gen.string (fun bytes ->
        match Scenario.of_string bytes with
        | Error _ -> true
        | Ok s -> Scenario.validate s = Ok ());
    run "property/fragmentation"
      Gen.(pair string_small (int_bound 15))
      (fun (bytes, allow) ->
        let config =
          { default_config with incoming_limit = 1024; outgoing_limit = 1024 }
        in
        let write_all = [ Write (0, allow); Write (0, 1024) ] in
        let s =
          Fixtures.scenario ~config "FRAG"
            ([ Open 0; Begin (0, 1, String.length bytes) ]
            @ List.init (String.length bytes) (fun i ->
                Input (0, String.make 1 bytes.[i]))
            @ [ Consume (0, String.length bytes); Send (0, 1, bytes) ]
            @ write_all @ [ Finish 0 ])
        in
        (Runner.run Contract.Correct s).failure = None);
  ]
