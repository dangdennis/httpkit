val scenario :
  ?config:Scenario.config -> string -> Scenario.action list -> Scenario.t

val fault_case : Contract.fault -> Scenario.t
val expected_rule : Contract.fault -> string
val happy : Scenario.t
