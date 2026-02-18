# AEA — Aeron Expressive Auction Prototype

A focused technical case study and prototype of a combinatorial auction clearing engine designed to eliminate legging risk in high-throughput, low-latency markets.

## Quick summary

- Project: AEA (Aeron Expressive Auction) Prototype
- Purpose: Treat order execution as an atomic combinatorial optimization to remove legging risk and maximize aggregate price improvement at batch auctions.
- Code anchors: `lib/matcher.ml` (OCaml solver wiring, constraints → MIP) and `rust-transport/src/main.rs` (market data publisher / prototype transport).

## The Why — Legging Risk and Atomic Matching

In FIFO venues, multi-leg execution (e.g., spread trades, crosses) exposes participants to legging risk: partial fills across legs create execution exposure and allow counterparties to exploit sequencing. Treating each multi-leg order as independent FIFO events imposes an implicit temporal dependency that can be gamed.

AEA removes this surface by making execution atomic: the entire order (all legs) either clears together under a single feasibility model or does not execute. The clearing problem becomes a single combinatorial optimization over order-legs and quantities — an NP-hard (NP-complete decision-form) instance in the general case that we solve using Mixed Integer Programming (MIP) and a branch-and-cut backend (HiGHS).

The economic objective we maximize is aggregate price improvement relative to per-symbol reference prices (clearing candidates). Formally:

$$
\max \; \sum (Price_{Limit} - Price_{Exec}) \times Qty
$$

where the sum runs over every executed leg; `Price_{Exec}` is the per-symbol clearing price (we use NBBO mid-price as the candidate in the prototype), and `Price_{Limit}` is the limit specified on the order leg.

## Architecture (Mermaid)

Zero-copy pipeline (intended production path):

```mermaid
flowchart LR
	subgraph Transport
		RUST["Rust Market Data Publisher"] -->|Zero-copy Aeron IPC| AERON[Aeron IPC]
	end

	AERON --> OCAML_FIX["OCaml FIX Parser / Market State"]
	OCAML_FIX --> MIP["OCaml MIP Builder (Lp DSL)
	→ HiGHS Solver"]
	MIP --> EXEC["Execution Reporter / Settlement"]

	note right of AERON: Prototype uses UnixDatagram socket (see rust-transport/src/main.rs)
```

Notes:
- The repo contains a minimal prototype transport (`rust-transport/src/main.rs`) that currently uses a Unix datagram socket for IPC; the architecture above replaces that socket with Aeron for production to enable zero-copy, shared-memory IPC.

## Optimization engine — deep dive (see `lib/matcher.ml`)

Core modeling decisions implemented in `lib/matcher.ml`:

- Decision variables
	- Binary execution indicator x_b for each incoming expressive bid b. (In code: `x_bid_<i>`.)
	- Continuous executed-quantity q_{b,l} for each leg l of bid b. (In code: `q_bid_<i>_leg_<j>`.)

- Objective
	- Constructed as a linear objective over executed quantities: for each leg, coefficient = (limit_price - clearing_price_candidate). The implementation collects these terms into the Lp DSL and calls `Lp_highs.solve`. This implements the LaTeX objective above.

- Reference/clearing price
	- A per-symbol clearing price candidate is computed from NBBO snapshots (prototype uses mid-price: (bid_px + ask_px) / 2). This price is stored in `clearing_prices` and used to compute per-leg price improvement.

- Constraints (how financial constraints are linearized)
	- All-or-None (AON)
		- For each leg: q_{b,l} = max_qty_{b,l} * x_b
		- Linear equality — enforces integer binary x_b to gate all legs simultaneously.

	- MinNotional
		- Sum_l (limit_price_l * q_{b,l}) >= min_notional * x_b
		- Linear inequality that activates only if x_b = 1; otherwise RHS = 0.

	- Ratio / Pair constraints
		- For a specified pair of symbols with integer ratio num:den: q_num * den = q_den * num
		- This equality is linear in the continuous q variables and enforces exact proportional execution across legs.

- Solver and numerics
	- The prototype uses the repo's lightweight Lp DSL to describe variables, objectives, and constraints, and delegates solving to HiGHS via `Lp_highs.solve ~msg:false`.
	- The code reads solver values from the returned `solution_map` using `Lp.compute_poly`, rounds executed quantities to the nearest integer for settlement, and falls back to zero executions on infeasible/error results.

Edge cases and practicalities handled in the code:
- Missing NBBO: a neutral fallback clearing price is used (100.0 in the current prototype).
- Infeasible models: the code detects solver errors and returns zeroed executions rather than panicking.

Implementation contract (inputs/outputs)
- Inputs: array of expressive bids (legs, per-leg limit and max_qty, constraint type), and a `Market_state.t` NBBO snapshot accessor.
- Output: `solution` containing `clearing_prices` and per-participant executed legs.

## Transport & performance engineering

Design goals: microsecond-level predictability, minimal copies, and throughput parity with exchange-grade market feeds.

- Aeron IPC
	- Production intent: Aeron (UDP-based, shared-memory capable) for zero-copy snapshots between the market data publisher and OCaml parser. Zero-copy avoids both kernel and user-space copies and reduces GC pressure on the OCaml side.

- Mechanical sympathy
	- Pin the transport thread(s) to dedicated CPU cores, isolate those cores with cgroups/isolcpus, and configure IRQ affinity to avoid unpredictable preemption.
	- Use cache-line aligned, preallocated buffers for hot-path structures. Keep the parsing and solver boundaries explicit to avoid unnecessary heap allocation in the fast path.
	- Keep the Aeron publisher single-producer, multiple-consumer friendly; the OCaml side should map the Aeron memory region read-only for lock-free visibility.

- Prototype note
	- `rust-transport/src/main.rs` currently implements a simple NBBO publisher using a Unix datagram socket and JSON serialization for rapid iteration. Replace this with an Aeron publisher for zero-copy production performance.

## Why OCaml + Rust

- OCaml
	- Strong algebraic data types and pattern matching make encoding complex auction constraints (expressive legs, ratio specifications, AON) concise and type-safe.
	- The garbage collector and higher-level abstractions accelerate iteration over the solver model and business logic without sacrificing clarity.

- Rust
	- Suited for the transport layer where predictable, memory-safe, low-level control matters: pinned threads, explicit buffer lifetimes, and minimal allocator usage.
	- The prototype's `rust-transport` demonstrates a natural separation: Rust owns the high-throughput IPC and serialization; OCaml owns the symbolic auction logic and solver orchestration.

## Future directions — mechanism design and incentive compatibility

AEA's optimization core focuses on allocative efficiency; extending the system for robust, adversary-resistant markets requires mechanism design work:

- Incentive compatibility
	- Explore strategyproof mechanism families (e.g., VCG variants) or approximation schemes that maintain incentive constraints under expressive bids.

- Adversarial defenses ("Dark Forest")
	- Detect and penalize manipulative patterns (sequencing probes, tiny-sweep liquidity grabs). Consider randomized tie-breaking, temporal batching, and reserve-price adjustments to reduce exploitable microstructure.

- Auditability and verifiability
	- Produce a minimal, machine-checkable proof of feasibility and surplus for each clearing (certificate of optimality) to enable settlement audits and post-trade verification.

## Try the prototype (minimal)

Build and run the market data publisher (prototype transport):

```bash
# publish NBBO (Rust prototype)
cd rust-transport
cargo run --release
```

Build the OCaml matcher (requires dune / opam environment):

```bash
# from repo root
dune build
# or to run the matcher binary if configured
dune exec ./bin/matcher_main.exe -- <args>
```