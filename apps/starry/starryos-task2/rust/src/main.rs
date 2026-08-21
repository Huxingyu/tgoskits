use std::{
    net::{SocketAddr, UdpSocket},
    thread,
    time::{Duration, Instant},
};

use task2_net_protocol::{
    ControlAction, ControlMessage, Endpoint, EndpointState, MAX_DATAGRAM_LEN, MessageKind,
    PollEvent, ReceiveEvent, RetryPolicy, SessionId,
};
use task3_model::{build_features, forward};

const SESSION: SessionId = SessionId::new(0x5452_5432);
const POLICY: RetryPolicy = match RetryPolicy::new(500, 5, 200, 5_000) {
    Ok(policy) => policy,
    Err(_) => panic!("invalid T2N1 policy"),
};

fn fail(message: &str) -> ! {
    println!("STARRY_T2N1_FAIL {message}");
    std::process::exit(1);
}

fn main() {
    let socket = UdpSocket::bind("0.0.0.0:4242")
        .unwrap_or_else(|error| fail(&format!("bind error={error}")));
    socket
        .set_nonblocking(true)
        .unwrap_or_else(|error| fail(&format!("nonblocking error={error}")));
    let peer: SocketAddr = "10.0.42.2:4242".parse().expect("valid peer address");
    let started = Instant::now();
    let mut endpoint = Endpoint::new(SESSION, POLICY, 0);
    let state_history = [300i32];
    let output_history = [0i32];
    let features = build_features(&state_history, &output_history, 500, 300, 0);
    println!(
        "TASK3_MODEL_READY model=task3-temporal-cnn-m0 \
         weights_sha256=53760db8aff4e391018dbc3394b6ebcd8e87777cf76445ab6b3255a62adbded6 \
         mode=in-guest"
    );
    let infer_started = Instant::now();
    let correction = forward(&features);
    let infer_us = infer_started.elapsed().as_micros();
    let control_value = (500.0 + correction * 1000.0).round().clamp(0.0, 1000.0) as i32;
    println!(
        "TASK3_INFER model=cnn output={} correction={:.6} infer_us={infer_us}",
        control_value, correction
    );
    println!(
        "TASK3_DETECTION model=cnn output={} source=guest-forward",
        control_value
    );
    let mut payload = [0u8; 12];
    let command = ControlMessage::new(ControlAction::SetOutput, control_value, 1)
        .unwrap_or_else(|_| fail("control construction"));
    let payload_len = command
        .encode(&mut payload)
        .unwrap_or_else(|_| fail("control encoding"));
    let mut outbound = [0u8; MAX_DATAGRAM_LEN];
    let transmission = endpoint
        .queue_reliable(
            MessageKind::Control,
            &payload[..payload_len],
            0,
            &mut outbound,
        )
        .unwrap_or_else(|error| fail(&format!("queue error={error}")));
    socket
        .send_to(&outbound[..transmission.datagram_len()], peer)
        .unwrap_or_else(|error| fail(&format!("send control error={error}")));
    println!(
        "STARRY_T2N1_READY local=0.0.0.0:4242 peer={peer} session=0x{:08x}",
        SESSION.get()
    );
    println!(
        "STARRY_T2N1_CONTROL_SENT seq={} value={control_value}",
        transmission.sequence().get()
    );

    let mut inbound = [0u8; MAX_DATAGRAM_LEN];
    let mut response = [0u8; MAX_DATAGRAM_LEN];
    let mut saw_ack = false;
    let mut saw_status = false;
    while started.elapsed() < Duration::from_secs(12) {
        let now_ms = started.elapsed().as_millis() as u64;
        match socket.recv_from(&mut inbound) {
            Ok((length, source)) => {
                let result = endpoint
                    .receive(&inbound[..length], now_ms, &mut response)
                    .unwrap_or_else(|error| fail(&format!("receive error={error}")));
                if result.response_len > 0 {
                    socket
                        .send_to(&response[..result.response_len], source)
                        .unwrap_or_else(|error| fail(&format!("send response error={error}")));
                }
                match result.event {
                    ReceiveEvent::Acknowledged { sequence } => {
                        saw_ack = true;
                        println!("STARRY_T2N1_ACK seq={}", sequence.get());
                    }
                    ReceiveEvent::Delivered { frame } if frame.kind() == MessageKind::Status => {
                        saw_status = true;
                        println!(
                            "STARRY_T2N1_STATUS_DELIVERED seq={} bytes={}",
                            frame.sequence().get(),
                            frame.payload().len()
                        );
                    }
                    ReceiveEvent::Heartbeat { .. } => {}
                    other => println!("STARRY_T2N1_EVENT event={other:?}"),
                }
                if saw_ack && saw_status && endpoint.state() == EndpointState::Active {
                    println!("STARRY_T2N1_PASS");
                    return;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) => fail(&format!("recv error={error}")),
        }

        let poll = endpoint
            .poll(now_ms, &mut outbound)
            .unwrap_or_else(|error| fail(&format!("timer error={error}")));
        if poll.datagram_len > 0 {
            socket
                .send_to(&outbound[..poll.datagram_len], peer)
                .unwrap_or_else(|error| fail(&format!("send timer error={error}")));
            if let PollEvent::Retransmit { sequence, attempt } = poll.event {
                println!(
                    "STARRY_T2N1_RETRANSMIT seq={} attempt={attempt}",
                    sequence.get()
                );
            }
        }
        if matches!(
            poll.event,
            PollEvent::RetryExhausted { .. } | PollEvent::HeartbeatTimeout
        ) {
            fail(&format!("safe event={:?}", poll.event));
        }
        thread::sleep(Duration::from_millis(10));
    }
    fail("timeout waiting for ACK and STATUS");
}
