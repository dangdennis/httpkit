open Devlib

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  List.iter
    (fun signal ->
      Sys.set_signal signal
        (Sys.Signal_handle (fun _ -> raise (Common.Error "Interrupted"))))
    [ Sys.sigint; Sys.sigterm ];
  try
    match List.tl (Array.to_list Sys.argv) with
    | [ "fingerprint" ] | [ "evidence"; "fingerprint" ] ->
        print_endline (Build.source_hash ())
    | [ "packages" ] | [ "evidence"; "packages" ] ->
        print_endline (Yojson.Basic.pretty_to_string (Build.locked_packages ()))
    | [] | [ "help" ] | [ "--help" ] ->
        print_endline
          "httpkit developer tools: validate, consumer, framework-test, \
           routing-test, databases, coverage, mutations, interop, performance, \
           bench, profile-bodies, endpoint-profile, framework-load, \
           personal-load, framework-validate, personal-validate, native-fuzz, \
           native-minimize, fuzz, fuzz-smoke, triage-timeout, release, \
           selftest, protocol-spikes, fingerprint, packages"
    | [ "validate" ]
    | [ "validate"; "5.5.0" ]
    | [ "evidence"; "validate"; "5.5.0" ] ->
        Validate.compiler ()
    | "framework-validate" :: args ->
        Common.validate_options ~values:[] ~flags:[ "--long"; "--skip-afl" ]
          args;
        Validate.acceptance "framework" args
    | "personal-validate" :: args ->
        Common.validate_options ~values:[] ~flags:[ "--long"; "--skip-afl" ]
          args;
        Validate.acceptance "personal" args
    | [ "runner-test" ] -> Runner_test.cleanup ()
    | [ "protocol-spikes" ] -> Protocol_spikes.main ()
    | [ "coordinator-test" ] -> Runner_test.coordinator ()
    | [ "coordinator-fixture"; code; directory ] ->
        ignore
          (Validate.sequence ~directory ~digest:(Build.source_hash ())
             [ ("fixture", [ "fixture-exit"; code ]) ])
    | [ "fixture-exit"; code ] -> exit (int_of_string code)
    | [ "bench-test" ] -> Benchmark_test.main ()
    | [ "bench-selection-test" ] -> Benchmark_test.selection ()
    | [ "cli-test" ] -> Cli_test.main ()
    | [ "performance" ] -> Performance.main ()
    | "profile-bodies" :: args ->
        Common.validate_options ~values:[ "--iterations" ] ~flags:[ "--stack" ]
          args;
        Performance.profile args
    | "fuzz" :: args ->
        Common.validate_options
          ~values:[ "--seconds"; "--target" ]
          ~flags:[] args;
        Fuzz.campaign args
    | "native-fuzz" :: args ->
        Common.validate_options
          ~values:
            [
              "--rounds";
              "--batches";
              "--seed";
              "--timeout";
              "--target";
              "--input";
            ]
          ~flags:[] args;
        Native_fuzz.main args
    | "native-minimize" :: args ->
        Common.validate_options
          ~values:
            [ "--target"; "--input"; "--attempts"; "--seconds"; "--timeout" ]
          ~flags:[] args;
        Native_minimize.main args
    | [ "fuzz-smoke" ] -> Fuzz.smoke ()
    | "triage-timeout" :: args ->
        Common.validate_options
          ~values:[ "--replays"; "--afl-seconds"; "--rounds" ]
          ~flags:[] args;
        Fuzz.triage args
    | "personal-load" :: args ->
        Common.validate_options
          ~values:
            [ "--mode"; "--seconds"; "--epoch-seconds"; "--rate"; "--binary" ]
          ~flags:[] args;
        Personal.main args
    | "endpoint-profile" :: args ->
        Common.validate_options
          ~values:[ "--seconds"; "--repetitions"; "--binary"; "--profile" ]
          ~flags:[] args;
        Endpoint_profile.main args
    | "framework-load" :: args ->
        Common.validate_options
          ~values:[ "--mode"; "--seconds"; "--binary"; "--database" ]
          ~flags:[] args;
        Load.main args
    | "bench" :: args ->
        Common.validate_options
          ~values:
            [
              "--family";
              "--samples";
              "--min-ms";
              "--case";
              "--seed";
              "--baseline";
            ]
          ~flags:[ "--quick"; "--external" ]
          args;
        Benchmarks.main args
    | "selftest" :: args -> Selftest.main args
    | [ "coverage" ] -> Coverage.main "core"
    | [ "coverage"; layer ] -> Coverage.main layer
    | [ "mutations" ] -> Mutations.main "core"
    | [ "mutations"; layer ] -> Mutations.main layer
    | [ "interop" ] -> Interop.main ()
    | [ "routing-test" ] -> Interop.routing ()
    | "framework-test" :: args ->
        Common.validate_options ~values:[ "--binary" ] ~flags:[] args;
        Framework.main args
    | "databases" :: args ->
        Common.validate_options ~values:[ "--binary" ] ~flags:[] args;
        Databases.main args
    | "release" :: args ->
        Common.validate_options ~values:[ "--output" ] ~flags:[] args;
        Release.main args
    | [ "evidence"; "check" ] -> Evidence.check "M0"
    | [ "evidence"; "check"; milestone ] -> Evidence.check milestone
    | [ "consumer"; name ] -> Consumers.dispatch name
    | "dune" :: args -> Build.call args
    | _ -> Common.fail "Unknown command; run tools/dev --help"
  with exn ->
    prerr_endline (Printexc.to_string exn);
    exit 2
