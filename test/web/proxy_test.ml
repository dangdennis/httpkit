module P = Httpkit.Proxy
module H = Httpkit_core.Headers

let headers fields = Result.get_ok (H.of_list fields)

let resolve ?ip_header fields =
  P.resolve ?ip_header ~trusted_peer:(( = ) "trusted") ~peer:"trusted"
    (headers fields)

let check = Segmentation_support.check

let policy () =
  List.iter
    (fun ip_header ->
      let name =
        match ip_header with
        | P.Forwarded_for -> "x-forwarded-for"
        | Real_ip -> "x-real-ip"
      in
      List.iter
        (fun ip ->
          check
            (resolve ~ip_header [ ("x-forwarded-proto", "https"); (name, ip) ]
            = Ok (Some { P.scheme = "https"; client_ip = ip }))
            "valid selected metadata")
        [ "192.0.2.1"; "2001:db8::1" ];
      List.iter
        (fun fields ->
          check
            (Result.is_error (resolve ~ip_header fields))
            "ambiguous metadata accepted";
          check
            (P.resolve ~ip_header
               ~trusted_peer:(fun _ -> false)
               ~peer:"public" (headers fields)
            = Ok None)
            "untrusted metadata interpreted")
        [
          [];
          [ (name, "192.0.2.1") ];
          [ ("x-forwarded-proto", "https") ];
          [ ("x-forwarded-proto", "https"); (name, "192.0.2.1, 192.0.2.2") ];
          [
            ("x-forwarded-proto", "https");
            (name, "192.0.2.1");
            (name, "192.0.2.1");
          ];
          [
            ("x-forwarded-proto", "https");
            ("x-forwarded-proto", "http");
            (name, "192.0.2.1");
          ];
          [ ("x-forwarded-proto", "ftp"); (name, "192.0.2.1") ];
          [ ("x-forwarded-proto", "https"); (name, "not-an-ip") ];
          [
            ("x-forwarded-proto", "https");
            (name, "192.0.2.1");
            ("forwarded", "for=192.0.2.1");
          ];
        ])
    [ P.Forwarded_for; P.Real_ip ];
  let dual =
    [
      ("x-forwarded-proto", "https");
      ("x-forwarded-for", "192.0.2.1");
      ("x-real-ip", "192.0.2.2");
      ("x-forwarded-host", "attacker.invalid");
    ]
  in
  check
    (resolve dual = Ok (Some { P.scheme = "https"; client_ip = "192.0.2.1" }))
    "default changed";
  check
    (resolve ~ip_header:P.Real_ip dual
    = Ok (Some { P.scheme = "https"; client_ip = "192.0.2.2" }))
    "selected header ignored";
  check
    (Result.is_error
       (resolve ~ip_header:P.Real_ip
          [ ("x-forwarded-proto", "https"); ("x-forwarded-for", "192.0.2.1") ]))
    "implicit fallback";
  let seen = ref [] in
  ignore
    (P.resolve
       ~trusted_peer:(fun peer ->
         seen := peer :: !seen;
         false)
       ~peer:"immediate-peer" (headers dual));
  check
    (!seen = [ "immediate-peer" ])
    "trust predicate did not receive immediate peer"

let () =
  Alcotest.run "trusted proxy policy"
    [
      ( "metadata",
        [
          Alcotest.test_case "explicit trust and header selection" `Quick policy;
        ] );
    ]
