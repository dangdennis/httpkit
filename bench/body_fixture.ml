(* Wire fixtures shared by body and exchange experiments; no runtime driver. *)
type direction = Request | Response
type framing = Fixed | Chunked of int | Close
type transport = Pieces of int | Irregular
type scheduling = Immediate | Deferred
type consumption = Owned_scan | Borrowed_scan | Collect

type config = {
  direction : direction;
  framing : framing;
  size : int;
  transport : transport;
  scheduling : scheduling;
  consumption : consumption;
}

type fixture = {
  config : config;
  body : string;
  wire : string;
  bigwire : Bigstringaf.t;
  arrivals : int array;
}

let frame framing body =
  match framing with
  | Fixed | Close -> body
  | Chunked chunk ->
      let buffer = Buffer.create (String.length body + 64) in
      let rec add offset =
        if offset < String.length body then (
          let len = min chunk (String.length body - offset) in
          Buffer.add_string buffer (Printf.sprintf "%x\r\n" len);
          Buffer.add_substring buffer body offset len;
          Buffer.add_string buffer "\r\n";
          add (offset + len))
      in
      add 0;
      Buffer.add_string buffer "0\r\n\r\n";
      Buffer.contents buffer

let fixture config =
  let { direction; framing; size; transport; scheduling = _; consumption = _ } =
    config
  in
  Suite_support.require ~message:"request cannot use close-delimited framing"
    (direction <> Request || framing <> Close);
  let body = String.init size (fun i -> Char.chr (((i * 31) + 7) land 255)) in
  let fields =
    match framing with
    | Fixed -> Printf.sprintf "Content-Length: %d\r\n" size
    | Chunked _ -> "Transfer-Encoding: chunked\r\n"
    | Close -> ""
  in
  let wire =
    (if direction = Request then "POST /body HTTP/1.1\r\nHost: x\r\n"
     else "HTTP/1.1 200 OK\r\n")
    ^ fields ^ "\r\n" ^ frame framing body
  in
  let pattern =
    match transport with
    | Pieces n -> [| n |]
    | Irregular -> [| 1; 7; 64; 3; 4096; 17; 8192 |]
  in
  let rec arrivals off i acc =
    if off = String.length wire then Array.of_list (List.rev acc)
    else
      let next =
        min (String.length wire) (off + pattern.(i mod Array.length pattern))
      in
      arrivals next (i + 1) (next :: acc)
  in
  {
    config;
    body;
    wire;
    bigwire = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire;
    arrivals = arrivals 0 0 [];
  }
