open Bidder_logic

type parse_error =
  | Missing_tag of int
  | Malformed_tag of int
  | Unsupported_msg_type of string
  | Unknown_tag of int

let parse_constraints_json (s : string) : Bidder_logic.constraint_ option =
  (* Extremely small JSON subset parser for known patterns only. *)
  let open Bidder_logic in
  let s = String.trim s in
  if s = "{\"type\":\"AllOrNone\"}" then Some AllOrNone
  else if String.length s >= 20 && String.contains s 'M' then
    (* Very narrow MinNotional pattern: {"type":"MinNotional","value":<float>} *)
    match String.index_opt s ':' with
    | None -> None
    | Some _ -> (
        try
          let idx = String.rindex s ':' in
          let num_str = String.sub s (idx + 1) (String.length s - idx - 2) in
          let v = float_of_string (String.trim num_str) in
          Some (MinNotional v)
        with _ -> None)
  else if String.length s >= 30 && String.contains s 'R' then
    (* Ratio pattern: {"type":"Ratio","num_symbol":"A","den_symbol":"B","num":1,"den":2} *)
    (* Very simple hand-rolled extraction - not a general JSON parser *)
    try
      (* Extract num_symbol *)
      let rec find_pattern start pattern =
        try
          let idx = String.index_from s start 'n' in
          if idx + String.length pattern <= String.length s &&
             String.sub s idx (String.length pattern) = pattern then
            idx
          else find_pattern (idx + 1) pattern
        with Not_found -> raise Not_found
      in
      let num_sym_idx = find_pattern 0 "num_symbol" in
      let num_sym_quote1 = String.index_from s (num_sym_idx + 12) '"' in
      let num_sym_quote2 = String.index_from s (num_sym_quote1 + 1) '"' in
      let num_symbol = String.sub s (num_sym_quote1 + 1) (num_sym_quote2 - num_sym_quote1 - 1) in
      
      (* Extract den_symbol *)
      let den_sym_idx = find_pattern (num_sym_quote2 + 1) "den_symbol" in
      let den_sym_quote1 = String.index_from s (den_sym_idx + 12) '"' in
      let den_sym_quote2 = String.index_from s (den_sym_quote1 + 1) '"' in
      let den_symbol = String.sub s (den_sym_quote1 + 1) (den_sym_quote2 - den_sym_quote1 - 1) in
      
      (* Extract num *)
      let num_key_idx = find_pattern (den_sym_quote2 + 1) "\"num\"" in
      let num_colon = String.index_from s (num_key_idx + 5) ':' in
      let num_comma = 
        try String.index_from s (num_colon + 1) ','
        with Not_found -> String.index_from s (num_colon + 1) '}'
      in
      let num_str = String.trim (String.sub s (num_colon + 1) (num_comma - num_colon - 1)) in
      let num = int_of_string num_str in
      
      (* Extract den *)
      let den_key_idx = find_pattern (num_comma + 1) "\"den\"" in
      let den_colon = String.index_from s (den_key_idx + 5) ':' in
      let den_end = String.index_from s (den_colon + 1) '}' in
      let den_str = String.trim (String.sub s (den_colon + 1) (den_end - den_colon - 1)) in
      let den = int_of_string den_str in
      
      Some (Ratio { num_symbol; den_symbol; num; den })
    with _ -> None
  else
    None

let field_sep = '\x01'

let parse_kv field =
  match String.index_opt field '=' with
  | None -> None
  | Some i ->
      let tag = String.sub field 0 i in
      let value = String.sub field (i + 1) (String.length field - i - 1) in
      Some (tag, value)

let parse_new_order_single s =
  let len = String.length s in
  let symbol = ref None
  and side = ref None
  and price = ref None
  and qty = ref None
  and constraints = ref None in
  let i = ref 0 in
  let msg_type = ref None in
  let error = ref None in
  while !i < len && !error = None do
    let j =
      match String.index_from_opt s !i field_sep with
      | None -> len
      | Some k -> k
    in
    let field = String.sub s !i (j - !i) in
    (match parse_kv field with
    | None -> ()
    | Some (tag, value) ->
        match tag with
        | "35" -> msg_type := Some value
        | "55" -> symbol := Some value
        | "54" ->
            side :=
              Some
                (match value with
                | "1" -> Buy
                | "2" -> Sell
                | _ -> raise (Invalid_argument "invalid side"))
    | "44" -> (
      try price := Some (float_of_string value) with _ -> error := Some (Malformed_tag 44))
    | "38" -> (
      try qty := Some (int_of_string value) with _ -> error := Some (Malformed_tag 38))
    | "20000" -> constraints := parse_constraints_json value
        | _ -> error := Some (Unknown_tag (int_of_string tag)));
    i := j + 1
  done;
  match !error with
  | Some e -> Error e
  | None -> (
      match !msg_type with
      | Some "D" -> (
    match (!symbol, !side, !price, !qty) with
    | Some sym, Some side, Some px, Some q ->
              let leg = { symbol = sym; side; limit_price = px; max_qty = q } in
              let bid =
                {
                  participant_id = "fix";
      legs = [| leg |];
      constraint_ = Option.value !constraints ~default:AllOrNone;
                }
              in
              Ok bid
          | _ -> Error (Missing_tag 0))
      | Some t -> Error (Unsupported_msg_type t)
      | None -> Error (Missing_tag 35))
