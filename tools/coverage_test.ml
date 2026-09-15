open Devlib

let () =
  List.iter
    (fun line ->
      assert (Coverage.summary_row line = Some ("lib/web_lwt/app.ml", 234, 291)))
    [
      " 80.41 %    234/291    lib/web_lwt/app.ml";
      "80.41% 234/291 lib/web_lwt/app.ml";
    ];
  List.iter
    (fun line -> assert (Coverage.summary_row line = None))
    [
      "100.00 % 0/0 lib/web/httpkit.ml";
      "64.02 % 3569/5575 Project coverage";
      "200 % 2/1 lib/core/header.ml";
      "nan % 1/1 lib/core/header.ml";
      "100 % 1/1 lib/core/header.ml trailing";
      "not coverage";
    ];
  print_endline
    "PASS coverage parsing accepts pinned reporter spacing and rejects invalid \
     counts"
