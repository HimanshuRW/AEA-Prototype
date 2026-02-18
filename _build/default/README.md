# AEA Prototype Matching Engine

## Overview

This repository contains a high-performance **Smart Market Matching Engine** prototype inspired by OneChronos. It implements a **batch call auction** system with deterministic OCaml business logic and a Rust-based market data publisher.

This system is designed as a serious production-grade foundation for a trading infrastructure team, prioritizing:

- **Determinism** over throughput
- **Correctness** over cleverness  
- **Explicit control** over memory and CPU behavior

---

## Architecture: Why These Choices?

### 1. Why Batch Call Auctions (Not Continuous Matching)?

**Batch call auctions** clear orders at fixed intervals (e.g., 1–5 ms) rather than matching trades continuously as orders arrive.

#### Advantages:

**Price Discovery & Fairness**
- All orders in an auction window compete on equal footing
- No advantage to co-location or sub-millisecond speed (within the interval)
- Clearing price reflects true supply/demand equilibrium for that period

**Support for Complex Order Types**
- Expressive bids with multiple legs can be evaluated holistically
- Constraints like `AllOrNone`, `MinNotional`, and exact `Ratio` requirements can be enforced correctly
- Greedy continuous matching would violate these constraints or require overly complex state machines

**Determinism & Reproducibility**
- Same inputs → same outputs, regardless of scheduling jitter or thread timing
- Critical for debugging, compliance, and regulatory audit
- Enables precise replay and testing

**Simplified State Management**
- No need for a full limit order book with complex priority queues
- Order intake is just a buffer; state resets after each auction
- Reduces complexity and memory management burden

#### Trade-offs:

- **Latency floor**: Orders wait until the next auction boundary (acceptable for 1–5 ms intervals)
- **Throughput ceiling**: Solving a Mixed Integer Program (MIP) every interval is more expensive than greedy matching
- **Design choice**: We explicitly favor correctness and expressiveness over raw speed

---

### 2. Why OCaml 5.x + Rust Split?

We split responsibilities by language based on their strengths:

| Component | Language | Why? |
|-----------|----------|------|
| **Business Logic** (matching, validation, optimization) | **OCaml 5.x** | Strong static typing, algebraic data types, pattern matching, safe immutability, excellent for modeling complex constraints |
| **Market Data Publishing** (low-latency IO) | **Rust** | Zero-cost abstractions, explicit memory control, predictable performance, no GC pauses |

#### OCaml for Business Logic:

- **Type safety**: The ML type system makes illegal states unrepresentable
- **No runtime surprises**: No hidden allocations or GC pauses in hot paths (when written carefully)
- **Pattern matching**: Expressive handling of bid types, constraints, and validation errors
- **HiGHS integration**: The `lp-highs` bindings provide clean access to a world-class MIP solver
- **Determinism**: OCaml's semantics and runtime behavior are well-understood and stable

#### Rust for Transport:

- **Predictable latency**: No garbage collector, full control over allocations
- **Zero-copy buffers**: Aeron IPC + Rust's ownership model = minimal data movement
- **CPU affinity**: Pin threads to cores for consistent performance
- **Systems programming**: Direct access to OS primitives for high-performance networking

#### Why Not One Language?

- **OCaml alone**: Would struggle with ultra-low-latency IO and explicit CPU/memory control for market data
- **Rust alone**: MIP solver integration is clunky; modeling complex business logic is verbose compared to OCaml's ADTs and pattern matching

**Verdict**: Use each language where it excels. OCaml for correctness and expressiveness, Rust for speed and control.

---

### 3. Why Mixed Integer Programming (Not Greedy Matching)?

**Greedy matching** (match orders as they arrive, best price first) is fast but **incorrect** for expressive order types.

#### Example: Ratio Constraint

```
Bid A: Buy 100 AAPL, Sell 200 MSFT (ratio 1:2 exact)
```

A greedy matcher might:
1. Match 100 AAPL (exhausting available liquidity)
2. Match 150 MSFT (liquidity runs out)
3. **Result**: Ratio violated → bid should be rejected, but greedy approach doesn't "see" the future

#### MIP Solution:

- **Variables**: Binary (`x_b` = execute bid or not), Continuous (`q_{b,l}` = quantity per leg)
- **Constraints**:
  - AllOrNone: `q_{b,l} = max_qty_{b,l} × x_b` for all legs
  - MinNotional: `Σ (limit_price × q) ≥ min_value × x_b`
  - Ratio: `q_num × den = q_den × num` (exact)
- **Objective**: Maximize aggregate price improvement `Σ (limit_price - clearing_price) × q`

**HiGHS** (the underlying solver) uses state-of-the-art branch-and-cut algorithms to find optimal solutions quickly.

#### Trade-offs:

- **Computational cost**: Solving a MIP is O(exponential) worst-case, but practical instances with 100–1000 orders solve in milliseconds
- **Latency**: Acceptable for 1–5 ms auction windows; not suitable for sub-microsecond continuous trading
- **Correctness**: Guaranteed feasibility and optimality (within numerical tolerance)

**Verdict**: MIP is the right tool for batch auctions with complex constraints. Greedy matching is fundamentally broken for this use case.

---

## System Design

### Components

```
┌─────────────────────────────────────────────────┐
│  Rust Market Data Publisher (rust-transport/)   │
│  - Publishes simulated NBBO every ~100µs        │
│  - Aeron IPC stream 10                          │
│  - CPU pinned, zero-copy buffers                │
└─────────────────┬───────────────────────────────┘
                  │ Aeron IPC
                  ▼
┌─────────────────────────────────────────────────┐
│  OCaml Batch Auction Engine (bin/, lib/)        │
│                                                  │
│  ┌─────────────────────────────────────────┐   │
│  │  Aeron Wiring (stream 10 + 20)          │   │
│  │  - Poll NBBO updates (stream 10)        │   │
│  │  - Poll incoming orders (stream 20)     │   │
│  └──────┬──────────────────────────────────┘   │
│         │                                        │
│         ▼                                        │
│  ┌─────────────────────────────────────────┐   │
│  │  FIX Parser                              │   │
│  │  - Parse FIX 4.2 NewOrderSingle (35=D)  │   │
│  │  - Extract tag 20000 (JSON constraints) │   │
│  └──────┬──────────────────────────────────┘   │
│         │                                        │
│         ▼                                        │
│  ┌─────────────────────────────────────────┐   │
│  │  Bidder Logic                            │   │
│  │  - Validate expressive bids              │   │
│  │  - Reject infeasible orders early        │   │
│  └──────┬──────────────────────────────────┘   │
│         │                                        │
│         ▼                                        │
│  ┌─────────────────────────────────────────┐   │
│  │  Market State                            │   │
│  │  - Per-symbol NBBO                       │   │
│  │  - Order intake buffer (fixed capacity) │   │
│  └──────┬──────────────────────────────────┘   │
│         │                                        │
│         ▼ (every auction interval)              │
│  ┌─────────────────────────────────────────┐   │
│  │  Matcher (HiGHS MIP)                     │   │
│  │  - Build MIP from bids + constraints     │   │
│  │  - Solve for optimal execution           │   │
│  │  - Extract clearing prices + quantities  │   │
│  └──────┬──────────────────────────────────┘   │
│         │                                        │
│         ▼                                        │
│  ┌─────────────────────────────────────────┐   │
│  │  Batch Auction Loop                      │   │
│  │  - Fixed interval (1ms default)          │   │
│  │  - No threads, no async, tight polling   │   │
│  └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

### Module Responsibilities (OCaml)

| Module | Purpose | Files |
|--------|---------|-------|
| **Bidder_logic** | Define expressive bid types, validation | `lib/bidder_logic.{ml,mli}` |
| **Market_state** | NBBO tracking, order intake buffer | `lib/market_state.{ml,mli}` |
| **Matcher** | MIP construction, HiGHS solving, result extraction | `lib/matcher.{ml,mli}` |
| **Fix_parser** | Minimal FIX 4.2 parser, custom tag 20000 JSON | `lib/fix_parser.{ml,mli}` |
| **Aeron_wiring** | Subscribe to Aeron streams 10 & 20 | `lib/aeron_wiring.{ml,mli}` |
| **Batch_auction** | Fixed-interval auction loop | `lib/batch_auction.{ml,mli}` |
| **matcher_main** | Entrypoint (no business logic) | `bin/matcher_main.ml` |

---

## Key Implementation Details

### 1. Expressive Bids (Bidder_logic)

```ocaml
type leg = {
  symbol : string;
  side : side;
  limit_price : float;
  max_qty : int;
}

type constraint_ =
  | AllOrNone
  | MinNotional of float
  | Ratio of { num_symbol; den_symbol; num; den }

type expressive_bid = {
  participant_id : string;
  legs : leg array;        (* Array, not list → cache locality *)
  constraint_ : constraint_;
}
```

**Validation** is allocation-free:
- Uses `while` loops over arrays (no intermediate lists)
- Returns `validation_error option` (no exceptions in hot path)
- Checks quantities, prices, constraint feasibility

### 2. Market State (Market_state)

```ocaml
type order_intake = {
  mutable bids : expressive_bid array;
  mutable count : int;
}
```

- Pre-allocates buffer with fixed capacity (e.g., 1024 orders)
- `add_order` returns `Accepted | Rejected_buffer_full` (explicit overflow handling)
- `reset_intake` sets `count = 0` (reuses array, no deallocation/reallocation)

### 3. Matcher (HiGHS MIP)

Uses the `lp` and `lp-highs` libraries:

```ocaml
let solve_batch ~market ~auction_orders =
  (* 1. Collect symbols, compute clearing prices from NBBO *)
  (* 2. Build MIP:
        - Binary vars: x_b (execute bid b?)
        - Continuous vars: q_{b,l} (quantity for bid b, leg l)
        - Objective: maximize Σ (limit_price - clearing_price) × q
        - Constraints: AllOrNone, MinNotional, Ratio
     *)
  (* 3. Solve with HiGHS *)
  (* 4. Extract solution, round quantities to integers *)
```

**Key insight**: Clearing prices are pre-computed from NBBO (mid-price) to keep objective linear.

### 4. FIX Parser (Fix_parser)

Minimal implementation:
- Supports only `35=D` (NewOrderSingle)
- Required tags: `55` (Symbol), `54` (Side), `44` (Price), `38` (OrderQty)
- Custom tag `20000`: JSON string for constraints
  - `{"type":"AllOrNone"}`
  - `{"type":"MinNotional","value":123.45}`
  - `{"type":"Ratio","num_symbol":"AAPL","den_symbol":"MSFT","num":1,"den":2}`

**No general JSON parser**: Hand-rolled extraction for these patterns only. Fail fast on malformed input.

### 5. Batch Auction Loop (Batch_auction)

```ocaml
let run ~interval_ns =
  let rec loop next_deadline =
    let now = monotonic_time_ns () in
    if now >= next_deadline then
      (* Auction window ends: solve, reset, advance deadline *)
      let orders = Array.sub market.intake.bids 0 market.intake.count in
      let _solution = Matcher.solve_batch ~market ~auction_orders:orders in
      Market_state.reset_intake market;
      loop (next_deadline + interval_ns)
    else
      (* Tight polling: check for new data *)
      Aeron_wiring.poll_once wiring market;
      loop next_deadline
```

**No threads, no async**: Just a tight loop with monotonic time checks.

---

## Deliberate Trade-offs

| What We Chose | What We Gave Up | Why |
|---------------|-----------------|-----|
| **Batch auctions** | Continuous sub-µs matching | Fairness, expressiveness, determinism |
| **MIP solver** | Greedy speed | Correctness for complex constraints |
| **OCaml + Rust** | Single-language simplicity | Best tool for each job |
| **Arrays, pre-allocation** | Idiomatic functional lists | Predictable memory, cache locality |
| **Fail-fast validation** | Permissive "best-effort" | Avoid silent errors, ensure quality |
| **Fixed capacity buffers** | Dynamic resizing | Explicit overflow handling, no surprises |

---

## Building and Running

### Prerequisites

- **OCaml 5.x** with `opam`
- **Dune** build system
- **HiGHS solver** (for `lp-highs`)
- **Rust** (for `rust-transport/`)

### Build OCaml

```bash
dune build @all
```

### Run Matcher

```bash
_build/default/bin/matcher_main.exe
```

(Currently runs with stubs for Aeron and Rust publisher)

### Build Rust Publisher

```bash
cd rust-transport
cargo build --release
```

---

## Current Status

| Task | Status | Notes |
|------|--------|-------|
| **1. Expressive Bid Model** | ✅ Complete | Validation, zero-alloc checks |
| **2. Market State** | ✅ Complete | NBBO tracking, intake buffer |
| **3. Matching Engine** | ✅ Complete | Full HiGHS MIP implementation |
| **4. FIX Parser** | ✅ Complete | Supports all constraint types via tag 20000 |
| **5. Aeron Wiring** | ⚙️ Stubbed | Real Aeron integration pending |
| **6. Rust Publisher** | ⚙️ Placeholder | Aeron-rs integration pending |
| **7. Batch Auction Loop** | ✅ Complete | Works with stubs |
| **8. Documentation** | ✅ Complete | This README |

---

## What's Next

1. **Integrate Aeron IPC**: Wire up `aeroon` in OCaml and `aeron-rs` in Rust
2. **End-to-end testing**: Rust publisher → OCaml matcher → execution results
3. **Performance tuning**: Profile solver times, optimize buffer sizes
4. **Monitoring**: Add metrics for auction solve times, order acceptance rates
5. **Compliance**: Audit logging, replay capability

---

## References

- **OneChronos**: Inspiration for architecture and transport (Aeron)
- **HiGHS**: https://highs.dev (MIP/LP solver)
- **Aeron**: https://github.com/real-logic/aeron (IPC transport)
- **OCaml `lp` library**: https://github.com/ktahar/ocaml-lp

---

## License

Proprietary prototype for evaluation purposes.
