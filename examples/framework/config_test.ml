let () =
  assert (Config.max_connections None = 16);
  List.iter
    (fun count ->
      assert (Config.max_connections (Some (string_of_int count)) = count))
    [ 1; 16; 64; 1024 ];
  List.iter
    (fun value ->
      match Config.max_connections (Some value) with
      | _ -> failwith "Unsafe example connection configuration accepted"
      | exception Invalid_argument _ -> ())
    [
      "";
      "0";
      "-1";
      "1025";
      "999999999999999999999999";
      "+64";
      " 64";
      "64\n";
      "0x40";
      "1_024";
    ]
