//! Minimal SNTP server: answers standard NTP client requests with this machine's clock,
//! so rover computes can sync using the stock `systemd-timesyncd` / `chronyd` clients.
//! Also serves the current time as JSON over HTTP, for one-shot `get-date.sh` syncs.
//!
//! Usage: time-server [NTP_ADDR] [HTTP_ADDR]   (defaults 0.0.0.0:123, 0.0.0.0:8123)

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Seconds between 1900-01-01 (NTP epoch) and 1970-01-01 (Unix epoch).
const NTP_UNIX_OFFSET: u64 = 2_208_988_800;
const NTP_PACKET_LEN: usize = 48;
const MODE_CLIENT: u8 = 3;
const MODE_SERVER: u8 = 4;

fn ntp_now() -> [u8; 8] {
    let d = unix_now();
    let secs = (d.as_secs() + NTP_UNIX_OFFSET) as u32;
    let frac = (((d.subsec_nanos() as u64) << 32) / 1_000_000_000) as u32;
    let mut out = [0u8; 8];
    out[..4].copy_from_slice(&secs.to_be_bytes());
    out[4..].copy_from_slice(&frac.to_be_bytes());
    out
}

fn build_response(req: &[u8; NTP_PACKET_LEN], rx: [u8; 8]) -> [u8; NTP_PACKET_LEN] {
    let version = (req[0] >> 3) & 0x7;
    let mut resp = [0u8; NTP_PACKET_LEN];
    resp[0] = (version << 3) | MODE_SERVER; // LI=0 (no leap warning)
    resp[1] = 1; // stratum 1: this machine is the reference clock
    resp[2] = req[2]; // echo poll interval
    resp[3] = (-20i8) as u8; // precision ~1µs
    // bytes 4..12: root delay / root dispersion = 0
    resp[12..16].copy_from_slice(b"LOCL"); // reference ID
    resp[16..24].copy_from_slice(&rx); // reference timestamp
    resp[24..32].copy_from_slice(&req[40..48]); // originate = client's transmit time
    resp[32..40].copy_from_slice(&rx); // receive timestamp
    resp[40..48].copy_from_slice(&ntp_now()); // transmit timestamp, taken as late as possible
    resp
}

fn unix_now() -> Duration {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before 1970")
}

fn handle_http(mut stream: TcpStream) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    // Read (and ignore) the request until the end of its headers; every path gets the same reply.
    let mut buf = [0u8; 4096];
    let mut len = 0;
    while len < buf.len() {
        let n = stream.read(&mut buf[len..])?;
        if n == 0 {
            break;
        }
        len += n;
        if buf[..len].windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    let d = unix_now();
    let body = format!(
        "{{\"unix_ns\":{},\"unix\":{}.{:09}}}\n",
        d.as_nanos(),
        d.as_secs(),
        d.subsec_nanos()
    );
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(resp.as_bytes())
}

fn serve_http(listener: TcpListener) {
    for stream in listener.incoming() {
        match stream {
            // One thread per connection so a slow client can't stall the others.
            Ok(s) => {
                thread::spawn(move || {
                    if let Err(e) = handle_http(s) {
                        eprintln!("http error: {e}");
                    }
                });
            }
            Err(e) => eprintln!("http accept error: {e}"),
        }
    }
}

fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let addr = args.next().unwrap_or_else(|| "0.0.0.0:123".to_string());
    let http_addr = args.next().unwrap_or_else(|| "0.0.0.0:8123".to_string());

    let sock = UdpSocket::bind(&addr)?;
    eprintln!("time-server listening on {addr} (ntp)");
    let listener = TcpListener::bind(&http_addr)?;
    eprintln!("time-server listening on {http_addr} (http/json)");
    thread::spawn(move || serve_http(listener));

    let mut req = [0u8; NTP_PACKET_LEN];
    loop {
        let (n, src) = match sock.recv_from(&mut req) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("recv error: {e}");
                continue;
            }
        };
        // Timestamp as soon as the request arrives.
        let rx = ntp_now();
        if n < NTP_PACKET_LEN || req[0] & 0x7 != MODE_CLIENT {
            continue;
        }
        if let Err(e) = sock.send_to(&build_response(&req, rx), src) {
            eprintln!("send to {src} failed: {e}");
        }
    }
}
