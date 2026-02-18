type solution_leg = {
  symbol : string;
  executed_qty : int;
}

type solution_bid = {
  participant_id : string;
  legs : solution_leg array;
}

type solution = {
  clearing_prices : (string, float) Hashtbl.t;
  executions : solution_bid array;
}

(* Helper: collect unique symbols from all bids *)
let collect_symbols (bids : Bidder_logic.expressive_bid array) : string list =
  let symbol_set = Hashtbl.create 16 in
  Array.iter (fun bid ->
    Array.iter (fun (leg : Bidder_logic.leg) ->
      Hashtbl.replace symbol_set leg.symbol ()
    ) bid.Bidder_logic.legs
  ) bids;
  Hashtbl.fold (fun sym () acc -> sym :: acc) symbol_set []

(* Helper: compute clearing price for a symbol from NBBO *)
let compute_clearing_price (market : Market_state.t) (symbol : string) : float =
  match Market_state.snapshot_nbbo market ~symbol with
  | Some nbbo ->
      (* Use mid-price as clearing price candidate *)
      (nbbo.bid_px +. nbbo.ask_px) /. 2.0
  | None ->
      (* No NBBO available, use a neutral price *)
      100.0

let solve_batch ~market ~auction_orders =
  let n = Array.length auction_orders in
  
  (* If no orders, return empty solution *)
  if n = 0 then
    { clearing_prices = Hashtbl.create 0; executions = [||] }
  else
    (* Step 1: Collect all symbols and compute clearing prices *)
    let symbols = collect_symbols auction_orders in
    let clearing_prices = Hashtbl.create (List.length symbols) in
    List.iter (fun symbol ->
      let price = compute_clearing_price market symbol in
      Hashtbl.add clearing_prices symbol price
    ) symbols;
    
    (* Step 2: Build MIP using Lp library's DSL *)
    let open Lp in
    
    (* Create decision variables:
       - For each bid b: binary variable x_b (whether bid executes)
       - For each leg l of bid b: continuous variable q_{b,l} (executed quantity)
    *)
    let bid_vars = Array.make n zero in
    let leg_vars = Array.make n [||] in
    
    (* Create variables and build objective *)
    let objective_terms = ref [] in
    
    Array.iteri (fun bid_idx bid ->
      (* Binary variable for bid execution *)
      let x_b = binary (Printf.sprintf "x_bid_%d" bid_idx) in
      bid_vars.(bid_idx) <- x_b;
      
      (* Continuous variables for leg quantities *)
      let n_legs = Array.length bid.Bidder_logic.legs in
      let leg_var_array = Array.make n_legs zero in
      
      Array.iteri (fun leg_idx leg ->
        (* Compute objective coefficient: price improvement *)
        let clearing_px = 
          Hashtbl.find_opt clearing_prices leg.Bidder_logic.symbol
          |> Option.value ~default:100.0
        in
        let price_improvement = leg.Bidder_logic.limit_price -. clearing_px in
        
        (* Create variable with bounds *)
        let q_var = var
          ~lb:0.0
          ~ub:(float_of_int leg.Bidder_logic.max_qty)
          (Printf.sprintf "q_bid_%d_leg_%d" bid_idx leg_idx) in
        
        leg_var_array.(leg_idx) <- q_var;
        
        (* Add to objective: price_improvement * q_var *)
        objective_terms := (c price_improvement *~ q_var) :: !objective_terms
      ) bid.Bidder_logic.legs;
      
      leg_vars.(bid_idx) <- leg_var_array
    ) auction_orders;
    
    (* Build objective: maximize total price improvement *)
    let objective = maximize (concat (Array.of_list !objective_terms)) in
    
    (* Step 3: Build constraints *)
    let constraints = ref [] in
    
    Array.iteri (fun bid_idx bid ->
      let x_b = bid_vars.(bid_idx) in
      let leg_qtys = leg_vars.(bid_idx) in
      
      match bid.Bidder_logic.constraint_ with
      | Bidder_logic.AllOrNone ->
          (* For AllOrNone: q_{b,l} = max_qty_{b,l} * x_b for all legs *)
          Array.iteri (fun leg_idx leg ->
            let q_var = leg_qtys.(leg_idx) in
            let max_qty = float_of_int leg.Bidder_logic.max_qty in
            (* q_var = max_qty * x_b *)
            let cnstr = eq
              ~name:(Printf.sprintf "aon_bid_%d_leg_%d" bid_idx leg_idx)
              q_var
              (c max_qty *~ x_b) in
            constraints := cnstr :: !constraints
          ) bid.Bidder_logic.legs
      
      | Bidder_logic.MinNotional min_value ->
          (* Sum of (limit_price * q) >= min_value * x_b *)
          let lhs_terms = Array.to_list (
            Array.mapi (fun leg_idx leg ->
              let q_var = leg_qtys.(leg_idx) in
              c leg.Bidder_logic.limit_price *~ q_var
            ) bid.Bidder_logic.legs
          ) in
          let lhs = concat (Array.of_list lhs_terms) in
          let rhs = c min_value *~ x_b in
          let cnstr = gt
            ~name:(Printf.sprintf "min_notional_bid_%d" bid_idx)
            lhs rhs in
          constraints := cnstr :: !constraints
      
      | Bidder_logic.Ratio { num_symbol; den_symbol; num; den } ->
          (* Find legs matching num_symbol and den_symbol *)
          let num_leg_idx = ref None in
          let den_leg_idx = ref None in
          Array.iteri (fun leg_idx leg ->
            if leg.Bidder_logic.symbol = num_symbol then
              num_leg_idx := Some leg_idx;
            if leg.Bidder_logic.symbol = den_symbol then
              den_leg_idx := Some leg_idx
          ) bid.Bidder_logic.legs;
          
          (match (!num_leg_idx, !den_leg_idx) with
          | Some num_idx, Some den_idx ->
              (* Exact ratio constraint: q_num * den = q_den * num *)
              let q_num = leg_qtys.(num_idx) in
              let q_den = leg_qtys.(den_idx) in
              let cnstr = eq
                ~name:(Printf.sprintf "ratio_bid_%d" bid_idx)
                (c (float_of_int den) *~ q_num)
                (c (float_of_int num) *~ q_den) in
              constraints := cnstr :: !constraints
          | _ -> 
              (* Invalid ratio specification - skip constraint *)
              ())
    ) auction_orders;
    
    (* Step 4: Create problem and solve *)
    let problem = make ~name:"aea_batch_auction" objective !constraints in
    
    let result = Lp_highs.solve ~msg:false problem in
    
    (* Step 5: Extract solution *)
    let executions =
      match result with
      | Ok (_obj_value, solution_map) ->
          Array.mapi (fun bid_idx bid ->
            let leg_qtys = leg_vars.(bid_idx) in
            let legs = Array.mapi (fun leg_idx leg ->
              let q_var = leg_qtys.(leg_idx) in
              let qty_val = 
                try Lp.compute_poly solution_map q_var
                with Not_found -> 0.0
              in
              let executed_qty = int_of_float (qty_val +. 0.5) in (* Round to nearest int *)
              { symbol = leg.Bidder_logic.symbol; executed_qty }
            ) bid.Bidder_logic.legs in
            { participant_id = bid.Bidder_logic.participant_id; legs }
          ) auction_orders
      | Error _err ->
          (* Infeasible or solver error - return zero executions *)
          Array.map (fun bid ->
            let legs = Array.map (fun leg ->
              { symbol = leg.Bidder_logic.symbol; executed_qty = 0 }
            ) bid.Bidder_logic.legs in
            { participant_id = bid.Bidder_logic.participant_id; legs }
          ) auction_orders
    in
    
    { clearing_prices; executions }
