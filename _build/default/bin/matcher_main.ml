open Aea

let () =
  (* Entrypoint: delegate all business logic to Batch_auction. *)
  Batch_auction.run ~interval_ns:(1_000_000)
