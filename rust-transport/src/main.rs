use std::os::unix::net::UnixDatagram;
use std::thread;
use std::time::Duration;
use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize, Debug)]
struct Nbbo {
    symbol: String,
    bid_px: f64,
    bid_sz: i32,
    ask_px: f64,
    ask_sz: i32,
}

fn main() {
    println!("[Rust Transport] Starting NBBO publisher");
    
    // Create Unix datagram socket for IPC (simpler than Aeron for prototype)
    let socket_path = "/tmp/aea_nbbo.sock";
    
    // Remove old socket if it exists
    let _ = std::fs::remove_file(socket_path);
    
    let socket = UnixDatagram::unbound()
        .expect("Failed to create Unix datagram socket");
    
    println!("[Rust Transport] Publishing NBBO updates to {}", socket_path);
    println!("[Rust Transport] Cadence: ~100 microseconds");
    
    // Simulated market data for a few symbols
    let mut counter = 0u64;
    
    loop {
        counter += 1;
        
        // Generate simulated NBBO for AAPL
        let aapl_nbbo = Nbbo {
            symbol: "AAPL".to_string(),
            bid_px: 150.0 + (counter as f64 % 10.0) * 0.1,
            bid_sz: 100 + (counter % 50) as i32,
            ask_px: 150.1 + (counter as f64 % 10.0) * 0.1,
            ask_sz: 100 + ((counter + 10) % 50) as i32,
        };
        
        // Generate simulated NBBO for MSFT
        let msft_nbbo = Nbbo {
            symbol: "MSFT".to_string(),
            bid_px: 300.0 + (counter as f64 % 20.0) * 0.1,
            bid_sz: 200 + (counter % 30) as i32,
            ask_px: 300.2 + (counter as f64 % 20.0) * 0.1,
            ask_sz: 200 + ((counter + 15) % 30) as i32,
        };
        
        // Serialize and send (one message per symbol)
        for nbbo in &[aapl_nbbo, msft_nbbo] {
            match serde_json::to_string(nbbo) {
                Ok(json) => {
                    let msg = format!("NBBO:{}\n", json);
                    // Try to send; ignore errors if socket doesn't exist yet
                    let _ = socket.send_to(msg.as_bytes(), socket_path);
                }
                Err(e) => {
                    eprintln!("[Rust Transport] Serialization error: {}", e);
                }
            }
        }
        
        // Sleep for ~100 microseconds (0.1 ms)
        thread::sleep(Duration::from_micros(100));
        
        // Print status every 10,000 iterations (~1 second)
        if counter % 10_000 == 0 {
            println!("[Rust Transport] Published {} updates", counter * 2);
        }
    }
}
