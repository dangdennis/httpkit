open Validation

type t = {
  reversed : Header.t list;
  count : int;
  bytes : int;
  max_fields : int;
  max_bytes : int;
}

let empty =
  { reversed = []; count = 0; bytes = 0; max_fields = 100; max_bytes = 65536 }

let create ?(max_fields = 100) ?(max_bytes = 65536) () =
  if max_fields < 0 || max_bytes < 0 then error Headers Invalid_limit
  else Ok { empty with max_fields; max_bytes }

let add field t =
  if t.count >= t.max_fields then error Headers Too_many_fields
  else
    let name = String.length (Header.Name.to_string (Header.name field)) in
    let value = String.length (Header.Value.to_string (Header.value field)) in
    (* Subtract from the remaining budget before adding. Even caller-supplied
       max_int limits must not let integer overflow turn a rejection into success. *)
    let remaining = t.max_bytes - t.bytes in
    if
      name > remaining
      || value > remaining - name
      || 4 > remaining - name - value
    then error Headers Too_long
    else
      Ok
        {
          t with
          reversed = field :: t.reversed;
          count = t.count + 1;
          bytes = t.bytes + name + value + 4;
        }

let of_list ?max_fields ?max_bytes fields =
  let* initial = create ?max_fields ?max_bytes () in
  let rec loop acc = function
    | [] -> Ok acc
    | (name, value) :: rest ->
        let* field = Header.of_strings name value in
        let* acc = add field acc in
        loop acc rest
  in
  loop initial fields

let to_list t = List.rev t.reversed

let get_all name t =
  List.fold_left
    (fun acc field ->
      if Header.Name.equal name (Header.name field) then
        Header.value field :: acc
      else acc)
    [] t.reversed

let length t = t.count
let wire_bytes t = t.bytes
