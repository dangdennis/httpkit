type 'body t = {
  status : Status.t;
  version : Version.t;
  headers : Headers.t;
  body : 'body;
}

let create ?(version = Version.Http_1_1) ?(headers = Headers.empty) ~status body
    =
  { status; version; headers; body }

let status t = t.status
let version t = t.version
let headers t = t.headers
let body t = t.body
let with_headers headers t = { t with headers }
let with_body body t = { t with body }
let map_body f t = with_body (f t.body) t
