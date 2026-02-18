(** Minimal FIX 4.2 parser for New Order Single with expressive constraints. *)

type parse_error =
  | Missing_tag of int
  | Malformed_tag of int
  | Unsupported_msg_type of string
  | Unknown_tag of int

val parse_new_order_single : string -> (Bidder_logic.expressive_bid, parse_error) result
