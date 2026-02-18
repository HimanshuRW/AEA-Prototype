(** Minimal but realistic market state for a batch call auction. *)

type side = Bid | Ask

type nbbo = {
  bid_px : float;
  bid_sz : int;
  ask_px : float;
  ask_sz : int;
}

type order_intake = {
  mutable bids : Bidder_logic.expressive_bid array;
  mutable count : int;
}

type t = {
  nbbo_by_symbol : (string, nbbo) Hashtbl.t;
  intake : order_intake;
}

type add_order_result =
  | Accepted
  | Rejected_buffer_full

val create : capacity:int -> t

val update_nbbo : t -> symbol:string -> nbbo -> unit

val snapshot_nbbo : t -> symbol:string -> nbbo option

val reset_intake : t -> unit

val add_order : t -> Bidder_logic.expressive_bid -> add_order_result
