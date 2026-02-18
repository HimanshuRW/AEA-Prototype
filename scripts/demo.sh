#!/bin/bash

# Complete end-to-end demo of AEA prototype

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     AEA Prototype - Complete End-to-End Demonstration         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

cd "$(dirname "$0")/.."

# Build
echo "[Step 1/5] Building system..."
dune build @all 2>&1 > /dev/null
cd rust-transport && cargo build --release --quiet && cd ..
echo "✅ Build complete"
echo ""

# Start Rust publisher
echo "[Step 2/5] Starting Rust NBBO publisher..."
rust-transport/target/release/aea-transport > /tmp/aea_rust.log 2>&1 &
RUST_PID=$!
echo "✅ Rust publisher started (PID: $RUST_PID)"
sleep 0.5
echo ""

# Start OCaml matcher
echo "[Step 3/5] Starting OCaml matching engine..."
_build/default/bin/matcher_main.exe > /tmp/aea_ocaml.log 2>&1 &
OCAML_PID=$!
echo "✅ OCaml matcher started (PID: $OCAML_PID)"
sleep 1
echo ""

# Inject orders
echo "[Step 4/5] Injecting test orders..."
python3 scripts/inject_orders.py
echo ""
sleep 2

# Show logs
echo "[Step 5/5] System activity (last 15 lines of each log):"
echo ""
echo "--- Rust Publisher Log ---"
tail -15 /tmp/aea_rust.log
echo ""
echo "--- OCaml Matcher Log ---"
tail -15 /tmp/aea_ocaml.log
echo ""

# Cleanup
echo "Shutting down..."
kill $RUST_PID $OCAML_PID 2>/dev/null || true
sleep 0.5

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                     ✅ DEMO COMPLETE ✅                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "What just happened:"
echo "  1. Rust published simulated NBBO updates every ~100µs"
echo "  2. OCaml received market data and ran batch auctions every 1ms"
echo "  3. Python injected 3 FIX orders with different constraint types"
echo "  4. OCaml parsed, validated, and processed the orders"
echo "  5. HiGHS MIP solver attempted to match orders optimally"
echo ""
echo "Key metrics:"
echo "  - Auction interval: 1ms"
echo "  - NBBO update rate: ~10,000/sec"
echo "  - Symbols tracked: AAPL, MSFT"
echo "  - Order constraints: AllOrNone, MinNotional"
echo ""
echo "Logs saved to: /tmp/aea_rust.log and /tmp/aea_ocaml.log"
