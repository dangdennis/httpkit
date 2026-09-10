type requirement = {
  id : string;
  rule : string;
  layer : string;
  source : string;
  cases : string list;
  implemented : bool;
}

let req id rule cases =
  {
    id;
    rule;
    layer = "harness-self";
    source = "project-policy";
    cases;
    implemented = true;
  }

let requirements =
  [
    req "SELF.INPUT.PREFIX" "Detect input overconsumption"
      [ "fault/overconsume" ];
    req "SELF.INPUT.EOF" "Detect empty-input/EOF confusion"
      [ "fault/empty-eof" ];
    req "SELF.OUTPUT.EXACT" "Detect dropped and duplicated output bytes"
      [ "fault/drop-write"; "fault/duplicate-write" ];
    req "SELF.COMMAND.ONCE" "Detect acceptance despite backpressure"
      [ "fault/double-accept" ];
    req "SELF.MESSAGE.TERMINAL"
      "Detect duplicate completion and data after completion"
      [ "fault/double-complete"; "fault/body-after-end" ];
    req "SELF.FRAME.NO_REUSE" "Detect unread data reused for a new message"
      [ "fault/reuse-unread" ];
    req "SELF.BODY.LIMIT" "Detect retained byte excess" [ "fault/overbuffer" ];
    req "SELF.CANCEL.WAKE" "Detect stranded cancellation waiter"
      [ "fault/miss-wakeup" ];
    req "SELF.TIME.ABSOLUTE" "Detect sliding header deadline"
      [ "fault/sliding-deadline" ];
    req "SELF.WORK.PROGRESS" "Detect unproductive runnable work"
      [ "fault/spin" ];
    req "SELF.REPLAY" "Replay fresh subjects with identical observations"
      [ "replay/100-times" ];
    req "SELF.SHRINK" "Preserve prerequisites and the failure category"
      [ "shrink/prerequisites" ];
    req "SELF.NORMALIZE" "Preserve message boundaries in normalized traces"
      [ "normalize/boundaries" ];
    {
      id = "H1.FRAME.CL_TE";
      rule = "Strictly reject ambiguous request framing";
      layer = "http1";
      source = "https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3";
      cases = [];
      implemented = false;
    };
    {
      id = "API.CORE.STANDALONE";
      rule = "Core values usable without an engine or runtime";
      layer = "core";
      source = "project-policy";
      cases = [];
      implemented = false;
    };
  ]

let pending_capabilities =
  [
    "core-values";
    "request-codec";
    "response-codec";
    "fixed-body";
    "chunked-body";
    "trailers";
    "persistence";
    "pipelined-input";
    "informational";
    "expect";
    "eof-early-response";
    "engine-cancellation";
    "upgrade-connect-handoff";
    "eio-adapter";
    "lwt-adapter";
  ]

let to_json () =
  `Assoc
    [
      ("scope", `String "harness-self evidence only");
      ( "requirements",
        `List
          (List.map
             (fun r ->
               `Assoc
                 [
                   ("id", `String r.id);
                   ("rule", `String r.rule);
                   ("layer", `String r.layer);
                   ("source", `String r.source);
                   ( "status",
                     `String
                       (if r.implemented then "IMPLEMENTED_SELF_TEST"
                        else "NOT_IMPLEMENTED") );
                   ("cases", `List (List.map (fun s -> `String s) r.cases));
                 ])
             requirements) );
      ( "pending_release_capabilities",
        `List (List.map (fun s -> `String s) pending_capabilities) );
    ]
