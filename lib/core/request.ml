type 'body t = {
  meth : Method.t;
  target : Target.t;
  version : Version.t;
  headers : Headers.t;
  body : 'body;
}

let create ?(version = Version.Http_1_1) ?(headers = Headers.empty) ~meth
    ~target body =
  { meth; target; version; headers; body }

let meth t = t.meth
let target t = t.target
let version t = t.version
let headers t = t.headers
let body t = t.body
let with_headers headers t = { t with headers }
let with_body body t = { t with body }
let map_body f t = with_body (f t.body) t
