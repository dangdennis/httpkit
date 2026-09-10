open Scenario
open Contract

let scenario ?(config = default_config) id actions =
  { id; role = Server; seed = "fixed-v1"; config; actions }

let happy =
  scenario "SELF.DUPLEX"
    [
      Open 0;
      Begin (0, 1, 4);
      Wait_body 0;
      Input (0, "abcd");
      Consume (0, 2);
      Send (0, 1, "reply");
      Write (0, 1);
      Write (0, 2);
      Write (0, 8);
      Consume (0, 2);
      Finish 0;
      Shutdown 0;
    ]

let fault_case fault =
  scenario
    ("SELF." ^ fault_name fault)
    (match fault with
    | Correct -> happy.actions
    | Drop_write | Duplicate_write ->
        [ Open 0; Send (0, 1, "abc"); Write (0, 1); Write (0, 2) ]
    | Overconsume -> [ Open 0; Input (0, "x") ]
    | Empty_eof -> [ Open 0; Input (0, "") ]
    | Double_accept ->
        [
          Open 0;
          Send (0, 1, "12345678");
          Send (0, 2, "x");
          Write (0, 8);
          Send (0, 2, "x");
          Write (0, 1);
        ]
    | Double_complete -> [ Open 0; Begin (0, 1, 0); Finish 0 ]
    | Body_after_end -> [ Open 0; Begin (0, 1, 0); Finish 0; Input (0, "x") ]
    | Reuse_unread ->
        [ Open 0; Begin (0, 1, 2); Input (0, "ab"); Begin (0, 2, 0) ]
    | Overbuffer -> [ Open 0; Begin (0, 1, 10); Input (0, "1234567890") ]
    | Miss_wakeup -> [ Open 0; Begin (0, 1, 1); Wait_body 0; Cancel 0 ]
    | Sliding_deadline -> [ Open 0; Advance 9L; Input (0, "x"); Advance 1L ]
    | Spin -> [ Open 0; Run (0, 5) ])

let expected_rule = function
  | Correct -> ""
  | Drop_write | Duplicate_write -> "OUTPUT.EXACT"
  | Overconsume -> "INPUT.PREFIX"
  | Empty_eof -> "INPUT.EOF"
  | Double_accept -> "COMMAND.ONCE"
  | Overbuffer -> "BODY.LIMIT"
  | Double_complete -> "MESSAGE.TERMINAL"
  | Body_after_end -> "INPUT.EXACT"
  | Reuse_unread -> "FRAME.NO_REUSE"
  | Miss_wakeup -> "CANCEL.WAKE"
  | Sliding_deadline -> "TIME.ABSOLUTE"
  | Spin -> "WORK.PROGRESS"
