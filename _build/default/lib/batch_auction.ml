let monotonic_time_ns () =
  (* Fallback: use gettimeofday-based monotonic approximation in nanoseconds. *)
  let secs = Unix.gettimeofday () in
  Int64.of_float (secs *. 1e9)

let run ~interval_ns =
  let market = Market_state.create ~capacity:1024 in
  let wiring = Aeron_wiring.create () in
  let auction_count = ref 0 in
  let rec loop next_deadline =
    let now = monotonic_time_ns () in
    if Int64.compare now next_deadline >= 0 then (
      (* End of auction window: solve and reset. *)
      incr auction_count;
      let orders = Array.sub market.intake.bids 0 market.intake.count in
      let solution = Matcher.solve_batch ~market ~auction_orders:orders in
      
      (* Print auction results every 1000 auctions (~1 second at 1ms intervals) *)
      if !auction_count mod 1000 = 0 then (
        Printf.printf "[Batch Auction #%d] Orders: %d, Symbols in NBBO: %d\n%!"
          !auction_count
          market.intake.count
          (Hashtbl.length market.nbbo_by_symbol);
        
        (* Print a sample of clearing prices *)
        if Hashtbl.length solution.clearing_prices > 0 then (
          Printf.printf "  Clearing prices: ";
          let count = ref 0 in
          Hashtbl.iter (fun sym price ->
            if !count < 3 then (
              Printf.printf "%s=$%.2f " sym price;
              incr count
            )
          ) solution.clearing_prices;
          Printf.printf "\n%!"
        )
      );
      
      Market_state.reset_intake market;
      let next = Int64.add next_deadline (Int64.of_int interval_ns) in
      loop next)
    else (
      Aeron_wiring.poll_once wiring market;
      loop next_deadline)
  in
  Printf.printf "[Batch Auction] Starting with %d ns interval (%.2f ms)\n%!"
    interval_ns (float_of_int interval_ns /. 1e6);
  let start = monotonic_time_ns () in
  let first_deadline = Int64.add start (Int64.of_int interval_ns) in
  loop first_deadline
