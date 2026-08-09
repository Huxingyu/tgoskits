//! Minimal UDP echo server for the task-2 dual-guest network smoke test.
//!
//! Listens on `0.0.0.0:4242` and echoes every datagram back to its sender,
//! printing a line per packet so the guest console can be correlated with the
//! pcap capture.

#[cfg(not(feature = "arceos"))]
use std::net::UdpSocket;

#[cfg(feature = "arceos")]
use ax_std::net::UdpSocket;

const LOCAL_PORT: u16 = 4242;

fn main() {
    let socket = UdpSocket::bind(("0.0.0.0", LOCAL_PORT)).expect("failed to bind UDP echo port");
    println!("udpecho ready on 0.0.0.0:{}", LOCAL_PORT);

    let mut buf = [0u8; 1500];
    loop {
        match socket.recv_from(&mut buf) {
            Ok((len, src)) => {
                let text = core::str::from_utf8(&buf[..len]).unwrap_or("<non-utf8>");
                println!("udpecho recv {} bytes from {}: {}", len, src, text);
                if let Err(err) = socket.send_to(&buf[..len], src) {
                    println!("udpecho send error: {:?}", err);
                }
            }
            Err(err) => {
                println!("udpecho recv error: {:?}", err);
            }
        }
    }
}
