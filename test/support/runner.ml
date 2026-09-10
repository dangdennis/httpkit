open Contract

type failure = {
  rule : string;
  step : int;
  message : string;
  expected : Yojson.Safe.t;
  actual : Yojson.Safe.t;
}

type report = {
  failure : failure option;
  trace : Yojson.Safe.t list;
  steps : int;
}

let rule action =
  let open Scenario in
  match action with
  | Input (_, "") -> "INPUT.EOF"
  | Input _ -> "INPUT.EXACT"
  | Write _ -> "OUTPUT.EXACT"
  | Send _ -> "COMMAND.ONCE"
  | Finish _ -> "MESSAGE.TERMINAL"
  | Begin _ -> "FRAME.NO_REUSE"
  | Cancel _ -> "CANCEL.WAKE"
  | Advance _ -> "TIME.ABSOLUTE"
  | Run _ -> "WORK.PROGRESS"
  | _ -> "MESSAGE.LIFECYCLE"

let view obs snaps =
  `Assoc
    [
      ("events", observations_to_json obs);
      ("resources", snapshots_to_json snaps);
    ]

let run_subject_unprotected (module S : SUBJECT) scenario =
  match Scenario.validate scenario with
  | Error e ->
      {
        failure =
          Some
            {
              rule = "SCENARIO.INVALID";
              step = 0;
              message = e;
              expected = `Null;
              actual = `Null;
            };
        trace = [];
        steps = 0;
      }
  | Ok () ->
      let subject = S.create scenario.config in
      let rec loop model trace steps index = function
        | [] -> { failure = None; trace = List.rev trace; steps }
        | action :: rest -> (
            let model, expected = Model.step model action in
            let expected_snap = Model.snapshots model in
            let expected_json = view expected expected_snap in
            try
              let actual = S.step subject action in
              let snaps = S.snapshots subject in
              let steps = steps + 1 + List.length actual in
              let actual_json = view actual snaps in
              let trace_item =
                `Assoc
                  [
                    ("index", `Int index);
                    ("action", Scenario.action_to_json action);
                    ("expected", expected_json);
                    ("actual", actual_json);
                  ]
              in
              let trace = trace_item :: trace in
              let fail rule message =
                {
                  failure =
                    Some
                      {
                        rule;
                        step = index;
                        message;
                        expected = expected_json;
                        actual = actual_json;
                      };
                  trace = List.rev trace;
                  steps;
                }
              in
              if steps > scenario.config.max_steps then
                fail "WORK.BUDGET" "operation budget exhausted"
              else if
                List.exists
                  (fun s ->
                    s.incoming > scenario.config.incoming_limit
                    || s.outgoing > scenario.config.outgoing_limit
                    || s.incoming < 0 || s.outgoing < 0)
                  snaps
              then fail "BODY.LIMIT" "retained bytes exceed configured capacity"
              else if
                match action with
                | Scenario.Input (_, s) ->
                    List.exists
                      (function
                        | _, Accepted_input n -> n < 0 || n > String.length s
                        | _ -> false)
                      actual
                | _ -> false
              then
                fail "INPUT.PREFIX" "accepted prefix is outside offered input"
              else if
                List.map (fun s -> (s.connection, s.deadline)) expected_snap
                <> List.map (fun s -> (s.connection, s.deadline)) snaps
                &&
                match action with
                | Scenario.Input (_, data) -> data <> ""
                | _ -> false
              then fail "TIME.ABSOLUTE" "input changed an absolute deadline"
              else if
                normalize expected <> normalize actual || expected_snap <> snaps
              then
                fail (rule action)
                  "first divergence from independent lifecycle model"
              else loop model trace steps (index + 1) rest
            with exn ->
              {
                failure =
                  Some
                    {
                      rule = "SUBJECT.EXCEPTION";
                      step = index;
                      message = Printexc.to_string exn;
                      expected = expected_json;
                      actual = `Null;
                    };
                trace = List.rev trace;
                steps;
              })
      in
      loop (Model.create scenario.config) [] 0 0 scenario.actions

let run_subject subject scenario =
  try run_subject_unprotected subject scenario
  with exn ->
    {
      failure =
        Some
          {
            rule = "SUBJECT.EXCEPTION";
            step = 0;
            message = Printexc.to_string exn;
            expected = `Null;
            actual = `Null;
          };
      trace = [];
      steps = 0;
    }

let run fault scenario = run_subject (Fake_subject.make fault) scenario

let failure_json f =
  `Assoc
    [
      ("rule", `String f.rule);
      ("step", `Int f.step);
      ("message", `String f.message);
      ("expected", f.expected);
      ("actual", f.actual);
    ]

let to_json r =
  `Assoc
    [
      ("status", `String (if r.failure = None then "PASS" else "FAIL"));
      ("subject_scope", `String "synthetic-harness-only");
      ("steps", `Int r.steps);
      ( "failure",
        match r.failure with None -> `Null | Some f -> failure_json f );
      ("trace", `List r.trace);
    ]

let same_failure a b =
  match (a.failure, b.failure) with
  | Some x, Some y -> x.rule = y.rule
  | _ -> false
