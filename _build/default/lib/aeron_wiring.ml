(* IPC wiring using Unix domain sockets (prototype implementation).
   This can be replaced with aeroon when Aeron bindings are ready. *)

type t = {
  nbbo_socket : Unix.file_descr option ref;
  order_socket : Unix.file_descr option ref; [@warning "-69"]
  buffer : bytes;
}

let create () =
  (* Create Unix domain sockets for NBBO (stream 10) and orders (stream 20) *)
  let nbbo_socket_path = "/tmp/aea_nbbo.sock" in
  let order_socket_path = "/tmp/aea_orders.sock" in
  
  (* Create the NBBO socket and bind it *)
  let nbbo_sock =
    try
      let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_DGRAM 0 in
      (* Remove old socket file if exists *)
      (try Unix.unlink nbbo_socket_path with Unix.Unix_error _ -> ());
      Unix.bind sock (Unix.ADDR_UNIX nbbo_socket_path);
      (* Set non-blocking *)
      Unix.set_nonblock sock;
      Some sock
    with e ->
      Printf.eprintf "[Aeron_wiring] Failed to create NBBO socket: %s\n%!"
        (Printexc.to_string e);
      None
  in
  
  (* Create the order socket and bind it *)
  let order_sock =
    try
      let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_DGRAM 0 in
      (* Remove old socket file if exists *)
      (try Unix.unlink order_socket_path with Unix.Unix_error _ -> ());
      Unix.bind sock (Unix.ADDR_UNIX order_socket_path);
      (* Set non-blocking *)
      Unix.set_nonblock sock;
      Some sock
    with e ->
      Printf.eprintf "[Aeron_wiring] Failed to create order socket: %s\n%!"
        (Printexc.to_string e);
      None
  in
  
  {
    nbbo_socket = ref nbbo_sock;
    order_socket = ref order_sock;
    buffer = Bytes.create 4096;
  }

let parse_nbbo_json json_str =
  (* Simple JSON parser for NBBO messages *)
  (* Format: {"symbol":"AAPL","bid_px":150.0,"bid_sz":100,"ask_px":150.1,"ask_sz":100} *)
  try
    let symbol = ref None in
    let bid_px = ref None in
    let bid_sz = ref None in
    let ask_px = ref None in
    let ask_sz = ref None in
    
    (* Very simple extraction - look for patterns *)
    let extract_string key json =
      try
        let pat = "\"" ^ key ^ "\":\"" in
        let idx = String.index_from json 0 (String.get pat 0) in
        let start_idx = ref idx in
        while !start_idx < String.length json &&
              String.sub json !start_idx (String.length pat) <> pat do
          start_idx := !start_idx + 1
        done;
        if !start_idx < String.length json then (
          let value_start = !start_idx + String.length pat in
          let value_end = String.index_from json value_start '"' in
          Some (String.sub json value_start (value_end - value_start))
        ) else None
      with _ -> None
    in
    
    let extract_float key json =
      try
        let pat = "\"" ^ key ^ "\":" in
        let idx = ref 0 in
        while !idx < String.length json &&
              (!idx + String.length pat > String.length json ||
               String.sub json !idx (String.length pat) <> pat) do
          idx := !idx + 1
        done;
        if !idx < String.length json then (
          let value_start = !idx + String.length pat in
          let value_end = ref value_start in
          while !value_end < String.length json &&
                let c = String.get json !value_end in
                (c >= '0' && c <= '9') || c = '.' || c = '-' do
            value_end := !value_end + 1
          done;
          Some (float_of_string (String.sub json value_start (!value_end - value_start)))
        ) else None
      with _ -> None
    in
    
    let extract_int key json =
      match extract_float key json with
      | Some f -> Some (int_of_float f)
      | None -> None
    in
    
    symbol := extract_string "symbol" json_str;
    bid_px := extract_float "bid_px" json_str;
    bid_sz := extract_int "bid_sz" json_str;
    ask_px := extract_float "ask_px" json_str;
    ask_sz := extract_int "ask_sz" json_str;
    
    match (!symbol, !bid_px, !bid_sz, !ask_px, !ask_sz) with
    | (Some sym, Some bpx, Some bsz, Some apx, Some asz) ->
        Some (sym, { Market_state.bid_px = bpx; bid_sz = bsz; ask_px = apx; ask_sz = asz })
    | _ -> None
  with e ->
    Printf.eprintf "[Aeron_wiring] JSON parse error: %s\n%!" (Printexc.to_string e);
    None

let poll_once t (market : Market_state.t) =
  (* Poll NBBO socket for market data updates *)
  (match !(t.nbbo_socket) with
  | None -> ()
  | Some sock ->
      (try
        while true do
          let n = Unix.recv sock t.buffer 0 (Bytes.length t.buffer) [] in
          if n > 0 then (
            let msg = Bytes.sub_string t.buffer 0 n in
            (* Messages are prefixed with "NBBO:" *)
            if String.length msg > 5 && String.sub msg 0 5 = "NBBO:" then (
              let json = String.sub msg 5 (String.length msg - 6) in (* remove "NBBO:" and "\n" *)
              match parse_nbbo_json json with
              | Some (symbol, nbbo) ->
                  Market_state.update_nbbo market ~symbol nbbo
              | None -> ()
            )
          )
        done
      with
      | Unix.Unix_error (Unix.EAGAIN, _, _)
      | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> ()
      | e ->
          Printf.eprintf "[Aeron_wiring] NBBO poll error: %s\n%!" (Printexc.to_string e)));
  
  (* Poll order socket for incoming orders *)
  (match !(t.order_socket) with
  | None -> ()
  | Some sock ->
      (try
        while true do
          let n = Unix.recv sock t.buffer 0 (Bytes.length t.buffer) [] in
          if n > 0 then (
            let msg = Bytes.sub_string t.buffer 0 n in
            (* Messages are prefixed with "ORDER:" *)
            if String.length msg > 6 && String.sub msg 0 6 = "ORDER:" then (
              let fix_msg = String.sub msg 6 (String.length msg - 7) in (* remove "ORDER:" and "\n" *)
              match Fix_parser.parse_new_order_single fix_msg with
              | Ok bid ->
                  (* Validate the bid *)
                  (match Bidder_logic.validate_expressive_bid bid with
                  | None ->
                      (* Valid bid, add to market state *)
                      (match Market_state.add_order market bid with
                      | Market_state.Accepted ->
                          Printf.printf "[Order Accepted] %s\n%!" bid.participant_id
                      | Market_state.Rejected_buffer_full ->
                          Printf.eprintf "[Order Rejected] Buffer full\n%!")
                  | Some err ->
                      Printf.eprintf "[Order Rejected] Validation error: %s\n%!"
                        (match err with
                        | Bidder_logic.Empty_legs -> "Empty legs"
                        | Bidder_logic.Negative_or_zero_qty -> "Negative or zero qty"
                        | Bidder_logic.Non_finite_price -> "Non-finite price"
                        | Bidder_logic.Invalid_ratio -> "Invalid ratio"
                        | Bidder_logic.Infeasible_min_notional -> "Infeasible min notional"))
              | Error err ->
                  Printf.eprintf "[Order Rejected] Parse error: %s\n%!"
                    (match err with
                    | Fix_parser.Missing_tag t -> Printf.sprintf "Missing tag %d" t
                    | Fix_parser.Malformed_tag t -> Printf.sprintf "Malformed tag %d" t
                    | Fix_parser.Unsupported_msg_type t -> Printf.sprintf "Unsupported msg type %s" t
                    | Fix_parser.Unknown_tag t -> Printf.sprintf "Unknown tag %d" t)
            )
          )
        done
      with
      | Unix.Unix_error (Unix.EAGAIN, _, _)
      | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> ()
      | e ->
          Printf.eprintf "[Aeron_wiring] Order poll error: %s\n%!" (Printexc.to_string e)))
