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

let create ~capacity =
  let nbbo_by_symbol = Hashtbl.create 32 in
  let dummy_bid =
    {
      Bidder_logic.participant_id = "";
      legs = [||];
      constraint_ = Bidder_logic.AllOrNone;
    }
  in
  let intake = { bids = Array.make capacity dummy_bid; count = 0 } in
  { nbbo_by_symbol; intake }

let update_nbbo t ~symbol nbbo = Hashtbl.replace t.nbbo_by_symbol symbol nbbo

let snapshot_nbbo t ~symbol = Hashtbl.find_opt t.nbbo_by_symbol symbol

let reset_intake t = t.intake.count <- 0

let add_order t bid =
  let idx = t.intake.count in
  if idx < Array.length t.intake.bids then (
    t.intake.bids.(idx) <- bid;
  t.intake.count <- idx + 1;
  Accepted)
  else
  Rejected_buffer_full
