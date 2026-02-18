(** Core types for expressive bids *)

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

(** Validation errors for expressive bids. We keep this small and fixed to
    avoid allocations in hot paths. *)
type validation_error =
  | Empty_legs
  | Negative_or_zero_qty
  | Non_finite_price
  | Invalid_ratio
  | Infeasible_min_notional

(** [validate_leg leg] performs pure validation of a single leg.
    It does not allocate and returns [None] on success or [Some error]
    on failure. *)
val validate_leg : leg -> validation_error option

(** [validate_expressive_bid bid] performs early rejection of infeasible
    bids. It uses only fixed-size operations (no allocation) and returns
    [None] if the bid passes basic structural validation or [Some error]
    otherwise. *)
val validate_expressive_bid : expressive_bid -> validation_error option
