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

val run_subject : (module Contract.SUBJECT) -> Scenario.t -> report
val run : Contract.fault -> Scenario.t -> report
val to_json : report -> Yojson.Safe.t
val same_failure : report -> report -> bool
