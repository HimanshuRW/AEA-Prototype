#!/usr/bin/env python3
"""
Simple FIX order injector for AEA prototype.
Sends FIX 4.2 NewOrderSingle messages via Unix socket.
"""

import socket
import time
import sys

def send_fix_order(symbol, side, price, qty, constraint_json=None):
    """Send a FIX NewOrderSingle message"""
    # FIX field separator
    SOH = '\x01'
    
    # Build FIX message
    fields = [
        f"35=D",  # MsgType = NewOrderSingle
        f"55={symbol}",  # Symbol
        f"54={side}",  # Side (1=Buy, 2=Sell)
        f"44={price}",  # Price
        f"38={qty}",  # OrderQty
    ]
    
    if constraint_json:
        fields.append(f"20000={constraint_json}")  # Custom JSON constraint tag
    
    fix_msg = SOH.join(fields) + SOH
    
    # Send via Unix socket
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.sendto(f"ORDER:{fix_msg}\n".encode(), "/tmp/aea_orders.sock")
        sock.close()
        return True
    except Exception as e:
        print(f"Error sending order: {e}", file=sys.stderr)
        return False

def main():
    print("AEA Order Injector")
    print("=" * 50)
    
    # Send some sample orders
    orders = [
        ("AAPL", 1, 150.5, 100, '{"type":"AllOrNone"}'),
        ("MSFT", 1, 300.0, 200, '{"type":"MinNotional","value":50000.0}'),
        ("AAPL", 2, 151.0, 50, '{"type":"AllOrNone"}'),
    ]
    
    for i, (symbol, side, price, qty, constraint) in enumerate(orders, 1):
        side_str = "Buy" if side == 1 else "Sell"
        print(f"[{i}] {side_str} {qty} {symbol} @ ${price} ({constraint})")
        if send_fix_order(symbol, side, price, qty, constraint):
            print("    ✅ Sent")
        else:
            print("    ❌ Failed")
        time.sleep(0.1)
    
    print("=" * 50)
    print("Orders sent successfully!")

if __name__ == "__main__":
    main()
