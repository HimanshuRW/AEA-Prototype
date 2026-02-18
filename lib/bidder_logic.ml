type side = Buy | Sell

type leg = {
  symbol : string;
  side : side;
  limit_price : float;
  max_qty : int;
}

type constraint_ =
  | AllOrNone
  | MinNotional of float
  | Ratio of {
      num_symbol : string;
      den_symbol : string;
      num : int;
      den : int;
    }

type expressive_bid = {
  participant_id : string;
  legs : leg array;
  constraint_ : constraint_;
}

type validation_error =
  | Empty_legs
  | Negative_or_zero_qty
  | Non_finite_price
  | Invalid_ratio
  | Infeasible_min_notional

let validate_leg (l : leg) : validation_error option =
  if l.max_qty <= 0 then Some Negative_or_zero_qty
  else if (Float.is_finite l.limit_price) = false then Some Non_finite_price
  else None

let validate_expressive_bid (b : expressive_bid) : validation_error option =
  let len = Array.length b.legs in
  if len = 0 then Some Empty_legs
  else (
    (* per-leg checks, no allocations, early exit *)
    let i = ref 0 in
    let err = ref None in
    while !i < len && !err = None do
      match validate_leg b.legs.(!i) with
      | None -> incr i
      | Some e -> err := Some e
    done;
    match !err with
    | Some _ as e -> e
    | None -> (
        match b.constraint_ with
        | AllOrNone -> None
        | MinNotional m ->
            if m <= 0.0 then Some Infeasible_min_notional else None
        | Ratio { num; den; _ } -> if num <= 0 || den <= 0 then Some Invalid_ratio else None
      ))
