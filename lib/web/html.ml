type t = string

let escape s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      Buffer.add_string b
        (match c with
        | '&' -> "&amp;"
        | '<' -> "&lt;"
        | '>' -> "&gt;"
        | '"' -> "&quot;"
        | '\'' -> "&#39;"
        | c -> String.make 1 c))
    s;
  Buffer.contents b

let text = escape

let name s =
  s <> ""
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true | _ -> false)
       s

let safe_url s =
  let lower = String.lowercase_ascii s in
  (not
     (String.exists
        (fun c -> Char.code c <= 32 || Char.code c = 127 || c = '\\')
        s))
  && ((not (String.contains s ':'))
     || String.starts_with ~prefix:"https://" lower
     || String.starts_with ~prefix:"http://" lower
     || String.starts_with ~prefix:"mailto:" lower)

let element ?(attrs = []) tag children =
  if
    not
      (List.mem tag
         [
           "html";
           "head";
           "title";
           "body";
           "main";
           "section";
           "article";
           "nav";
           "header";
           "footer";
           "div";
           "span";
           "p";
           "a";
           "h1";
           "h2";
           "h3";
           "ul";
           "ol";
           "li";
           "form";
           "label";
           "input";
           "button";
           "textarea";
           "select";
           "option";
           "table";
           "thead";
           "tbody";
           "tr";
           "td";
           "th";
           "pre";
           "code";
           "strong";
           "em";
           "img";
           "br";
           "hr";
           "meta";
           "link";
         ])
  then invalid_arg "unsupported HTML element";
  let seen = Hashtbl.create 8 in
  let attrs =
    List.map
      (fun (k, v) ->
        if
          (not (name k))
          || (not
                (List.mem k
                   [
                     "id";
                     "class";
                     "title";
                     "lang";
                     "dir";
                     "href";
                     "src";
                     "alt";
                     "width";
                     "height";
                     "action";
                     "method";
                     "enctype";
                     "name";
                     "value";
                     "type";
                     "placeholder";
                     "required";
                     "disabled";
                     "checked";
                     "selected";
                     "for";
                     "role";
                     "tabindex";
                     "rel";
                     "colspan";
                     "rowspan";
                   ]
                || String.starts_with ~prefix:"aria-" k
                || String.starts_with ~prefix:"data-" k))
          || Hashtbl.mem seen k
        then invalid_arg "unsafe HTML attribute";
        Hashtbl.add seen k ();
        if
          List.mem k [ "href"; "src"; "action"; "formaction" ]
          && not (safe_url v)
        then invalid_arg "unsafe HTML URL";
        " " ^ k ^ "=\"" ^ escape v ^ "\"")
      attrs
    |> String.concat ""
  in
  if List.mem tag [ "input"; "img"; "br"; "hr"; "meta"; "link" ] then (
    if children <> [] then invalid_arg "void element children";
    "<" ^ tag ^ attrs ^ ">")
  else "<" ^ tag ^ attrs ^ ">" ^ String.concat "" children ^ "</" ^ tag ^ ">"

let render t = t
