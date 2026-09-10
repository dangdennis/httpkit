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

let core id rule source cases =
  { id; rule; source; cases; layer = "core-values"; implemented = true }

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
    core "CORE.METHOD.TOKEN" "Validate case-sensitive method tokens"
      "https://www.rfc-editor.org/rfc/rfc9110.html#section-9.1"
      [ "core/method-alphabet"; "core/case-and-duplicates" ];
    core "CORE.HEADER.LEXICAL"
      "Reject invalid fields and preserve duplicate order"
      "https://www.rfc-editor.org/rfc/rfc9110.html#section-5.5"
      [
        "core/name-alphabet";
        "core/value-alphabet";
        "core/injection";
        "core/case-and-duplicates";
      ];
    core "CORE.HEADER.OWS"
      "Reject surrounding whitespace at the value constructor" "project-policy"
      [ "core/value-ows" ];
    core "CORE.TARGET.RAW"
      "Validate lexical targets without decoding or normalization"
      "project-policy"
      [ "core/target-alphabet"; "core/target-escapes" ];
    core "CORE.LIMITS" "Bound individual fields and aggregate retained headers"
      "project-policy"
      [
        "core/scalar-limits"; "core/header-budgets"; "core/default-field-limit";
      ];
    core "CORE.STATUS" "Accept status codes 100 through 599"
      "https://www.rfc-editor.org/rfc/rfc9110.html#section-15"
      [ "core/status-range" ];
    core "CORE.BODY"
      "Preserve caller body ownership and support type-changing mapping"
      "project-policy"
      [ "core/body-polymorphism" ];
    core "CORE.ERROR" "Keep untrusted bytes out of diagnostics" "project-policy"
      [ "core/bounded-errors" ];
    {
      id = "H1.FRAME.CL_TE";
      rule = "Strictly reject ambiguous request framing";
      layer = "http1";
      source = "https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3";
      cases = [ "http1/reject/cl-te" ];
      implemented = true;
    };
    {
      id = "API.CORE.STANDALONE";
      rule = "Core values usable without an engine or runtime";
      layer = "core-install";
      source = "project-policy";
      cases = [ "tools/test_core_consumer.py" ];
      implemented = true;
    };
  ]

let requirements =
  requirements
  @ List.map
      (fun (id, rule, source, cases) ->
        { id; rule; source; cases; layer = "http1"; implemented = true })
      [
        ( "H1.HEAD",
          "Strict head syntax and authority before dispatch",
          "https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2",
          [
            "http1/head/origin";
            "http1/head/absolute";
            "http1/reject/authority-conflict";
            "http1/reject/bare-lf";
          ] );
        ( "H1.BODY",
          "Exact fixed/chunked boundaries and truncation",
          "https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3",
          [
            "http1/body/fragments";
            "http1/body/truncated";
            "http1/close-and-eof";
          ] );
        ( "H1.CHUNK",
          "Chunk grammar and declared safe trailers",
          "https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1",
          [ "http1/body/chunk-reject"; "http1/body/serialization" ] );
        ( "H1.LIMITS",
          "Bounded metadata, per-call work and optional body quota",
          "project-policy",
          [ "http1/limits"; "http1/slices" ] );
        ( "H1.OUTPUT",
          "Validate before encoding and enforce outbound length",
          "project-policy",
          [ "http1/head/serialization"; "http1/body/serialization" ] );
      ]

let requirements =
  requirements
  @ List.map
      (fun (id, rule, cases) ->
        {
          id;
          rule;
          source = "project-policy";
          cases;
          layer = "engine";
          implemented = true;
        })
      [
        ( "ENGINE.ORDER",
          "Serial admission and exact partial output",
          [ "engine/server/pipeline"; "engine/output/backpressure" ] );
        ( "ENGINE.BODY",
          "Body demand, early response and safe discard",
          [
            "engine/input/backpressure";
            "engine/server/early-final";
            "engine/server/discard";
            "engine/client/early-final";
          ] );
        ( "ENGINE.CANCEL",
          "Terminal cancellation, EOF and shutdown",
          [
            "engine/abort/once";
            "engine/eof/fixed";
            "engine/eof/half-close";
            "engine/shutdown";
          ] );
        ( "ENGINE.INFO",
          "Bounded informational responses and Expect",
          [
            "engine/server/informational";
            "engine/client/info-bound";
            "engine/client/expect";
            "engine/client/expect-override";
          ] );
        ( "ENGINE.HANDOFF",
          "Negotiated handoff after output acknowledgement",
          [
            "engine/handoff/connect";
            "engine/handoff/upgrade";
            "engine/handoff/client-connect";
            "engine/handoff/unsolicited";
          ] );
        ( "ENGINE.OWNERSHIP",
          "Connection-local identity and independent domains",
          [
            "engine/ids/ownership"; "engine/model/domains"; "engine/ack/invalid";
          ] );
      ]

let pending_capabilities = [ "eio-adapter"; "lwt-adapter" ]

let to_json () =
  `Assoc
    [
      ( "scope",
        `String
          "synthetic harness and core values; implemented is not a validation \
           result" );
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
                       (if r.implemented then
                          if r.layer = "harness-self" then
                            "IMPLEMENTED_SELF_TEST"
                          else "IMPLEMENTED_SUBJECT_TEST"
                        else "NOT_IMPLEMENTED") );
                   ("cases", `List (List.map (fun s -> `String s) r.cases));
                 ])
             requirements) );
      ( "pending_release_capabilities",
        `List (List.map (fun s -> `String s) pending_capabilities) );
    ]
