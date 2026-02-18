(** Matching engine that converts expressive bids into a MIP for HiGHS. *)

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

val solve_batch :
  market:Market_state.t ->
  auction_orders:Bidder_logic.expressive_bid array ->
  solution
