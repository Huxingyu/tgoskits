use std::{
    env,
    net::{SocketAddr, UdpSocket},
    thread,
    time::{Duration, Instant},
};

use task2_net_protocol::{
    ControlAction, ControlMessage, Endpoint, EndpointState, Frame, MAX_DATAGRAM_LEN, MessageKind,
    PollEvent, ReceiveEvent, RetryPolicy, SequenceNumber, SessionId, StatusMessage,
};
use task3_model::{build_features, forward};

const SESSION: SessionId = SessionId::new(0x5452_5432);
const POLICY: RetryPolicy = match RetryPolicy::new(500, 5, 200, 5_000) {
    Ok(policy) => policy,
    Err(_) => panic!("invalid T2N1 policy"),
};
const CONTROL_INTERVAL_MS: u64 = 1_000;
const MAX_INFERENCE_US: u128 = 1_000_000;
const CONTROL_TARGET: i32 = 500;
const INITIAL_STATE: i32 = 300;
const MODEL_SHA256: &str = "53760db8aff4e391018dbc3394b6ebcd8e87777cf76445ab6b3255a62adbded6";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RunMode {
    Normal,
    OutOfOrder,
    InvalidParameter,
    ModelRejected,
}

impl RunMode {
    fn parse(value: Option<&str>) -> Result<Self, &'static str> {
        match value {
            None | Some("normal") => Ok(Self::Normal),
            Some("out-of-order") => Ok(Self::OutOfOrder),
            Some("invalid-parameter") => Ok(Self::InvalidParameter),
            Some("model-rejected") => Ok(Self::ModelRejected),
            Some(_) => {
                Err("mode must be normal, out-of-order, invalid-parameter, or model-rejected")
            }
        }
    }

    const fn name(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::OutOfOrder => "out-of-order",
            Self::InvalidParameter => "invalid-parameter",
            Self::ModelRejected => "model-rejected",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InferenceRejection {
    DeadlineExceeded,
    NonFiniteOutput,
    OutputOutOfRange,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct InferenceOutput {
    correction: f64,
    control_value: i32,
    infer_us: u128,
}

struct ControlLoop {
    mode: RunMode,
    request_id: u32,
    request_in_flight: bool,
    pending_send: bool,
    request_sent_at_ms: u64,
    next_send_at_ms: u64,
    successful_cycles: u32,
    first_success_reported: bool,
    status_received: bool,
    fault_injected: bool,
    protocol_safe_observed: bool,
    recovery_pending: bool,
    model_rejected: bool,
}

fn main() {
    if let Err(error) = run() {
        fail(&error);
    }
}

fn run() -> Result<(), String> {
    let mode = parse_run_mode()?;
    let socket = UdpSocket::bind("0.0.0.0:4242").map_err(|error| format!("bind error={error}"))?;
    socket
        .set_nonblocking(true)
        .map_err(|error| format!("nonblocking error={error}"))?;
    let peer: SocketAddr = "10.0.42.2:4242"
        .parse()
        .map_err(|error| format!("peer address error={error}"))?;
    let started = Instant::now();
    let mut endpoint = Endpoint::new(SESSION, POLICY, 0);
    let mut control = ControlLoop::new(mode);
    let mut inbound = [0u8; MAX_DATAGRAM_LEN];
    let mut response = [0u8; MAX_DATAGRAM_LEN];
    let mut outbound = [0u8; MAX_DATAGRAM_LEN];

    println!(
        "TASK3_MODEL_READY model=task3-temporal-cnn-m0 weights_sha256={MODEL_SHA256} \
         mode=in-guest run_mode={}",
        mode.name()
    );
    println!(
        "STARRY_T2N1_READY local=0.0.0.0:4242 peer={peer} session=0x{:08x} mode={}",
        SESSION.get(),
        mode.name()
    );
    control.send_if_due(&socket, &peer, &mut endpoint, &mut outbound, 0)?;

    loop {
        let now_ms = elapsed_ms(&started);
        receive_datagram(
            &socket,
            &peer,
            &mut endpoint,
            &mut control,
            &mut inbound,
            &mut response,
            now_ms,
        )?;
        poll_endpoint(
            &socket,
            &peer,
            &mut endpoint,
            &mut control,
            &mut outbound,
            now_ms,
        )?;
        control.send_if_due(&socket, &peer, &mut endpoint, &mut outbound, now_ms)?;
        control.report_first_success(&endpoint);
        thread::sleep(Duration::from_millis(10));
    }
}

fn parse_run_mode() -> Result<RunMode, String> {
    let mut arguments = env::args().skip(1);
    let mode_argument = arguments.next();
    let mode = RunMode::parse(mode_argument.as_deref()).map_err(str::to_owned)?;
    if arguments.next().is_some() {
        return Err("only one run-mode argument is accepted".to_owned());
    }
    Ok(mode)
}

fn receive_datagram(
    socket: &UdpSocket,
    peer: &SocketAddr,
    endpoint: &mut Endpoint,
    control: &mut ControlLoop,
    inbound: &mut [u8; MAX_DATAGRAM_LEN],
    response: &mut [u8; MAX_DATAGRAM_LEN],
    now_ms: u64,
) -> Result<(), String> {
    let (length, source) = match socket.recv_from(inbound) {
        Ok(received) => received,
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
        Err(error) => return Err(format!("recv error={error}")),
    };
    let state_before_receive = endpoint.state();
    let result = endpoint
        .receive(&inbound[..length], now_ms, response)
        .map_err(|error| format!("receive error={error}"))?;
    if result.response_len > 0 {
        send_datagram(
            socket,
            &source,
            &response[..result.response_len],
            "response",
        )?;
    }
    control.handle_receive_event(result.event, endpoint, now_ms);

    match (state_before_receive, endpoint.state()) {
        (EndpointState::Active, EndpointState::Safe) => {
            control.enter_protocol_safe("receive", now_ms);
        }
        (EndpointState::Safe, EndpointState::Active) => {
            control.recover(now_ms);
        }
        _ => {}
    }
    if source != *peer {
        println!("STARRY_T2N1_EVENT unexpected_source={source}");
    }
    Ok(())
}

fn poll_endpoint(
    socket: &UdpSocket,
    peer: &SocketAddr,
    endpoint: &mut Endpoint,
    control: &mut ControlLoop,
    outbound: &mut [u8; MAX_DATAGRAM_LEN],
    now_ms: u64,
) -> Result<(), String> {
    let poll = endpoint
        .poll(now_ms, outbound)
        .map_err(|error| format!("timer error={error}"))?;
    if poll.datagram_len > 0 {
        send_datagram(socket, peer, &outbound[..poll.datagram_len], "timer")?;
    }
    match poll.event {
        PollEvent::Retransmit { sequence, attempt } => println!(
            "STARRY_T2N1_RETRANSMIT seq={} attempt={attempt}",
            sequence.get()
        ),
        PollEvent::RetryExhausted { sequence } => {
            println!(
                "STARRY_T2N1_RETRY_EXHAUSTED seq={} elapsed_ms={now_ms}",
                sequence.get()
            );
            control.enter_protocol_safe("RetryExhausted", now_ms);
        }
        PollEvent::HeartbeatTimeout => {
            control.enter_protocol_safe("HeartbeatTimeout", now_ms);
        }
        PollEvent::Idle | PollEvent::HeartbeatSent => {}
    }
    Ok(())
}

impl ControlLoop {
    const fn new(mode: RunMode) -> Self {
        Self {
            mode,
            request_id: 1,
            request_in_flight: false,
            pending_send: false,
            request_sent_at_ms: 0,
            next_send_at_ms: 0,
            successful_cycles: 0,
            first_success_reported: false,
            status_received: false,
            fault_injected: false,
            protocol_safe_observed: false,
            recovery_pending: false,
            model_rejected: false,
        }
    }

    fn send_if_due(
        &mut self,
        socket: &UdpSocket,
        peer: &SocketAddr,
        endpoint: &mut Endpoint,
        outbound: &mut [u8; MAX_DATAGRAM_LEN],
        now_ms: u64,
    ) -> Result<(), String> {
        if endpoint.state() != EndpointState::Active
            || self.request_in_flight
            || self.model_rejected
            || now_ms < self.next_send_at_ms
        {
            return Ok(());
        }
        if endpoint.has_pending_frame() {
            if !self.pending_send {
                println!("STARRY_T2N1_CONTROL_DEFERRED awaiting_ack=true");
            }
            self.pending_send = true;
            return Ok(());
        }
        self.pending_send = false;

        if !self.fault_injected
            && matches!(self.mode, RunMode::OutOfOrder | RunMode::InvalidParameter)
        {
            return self.send_fault(socket, peer, outbound, now_ms);
        }
        self.send_inference_control(socket, peer, endpoint, outbound, now_ms)
    }

    fn send_fault(
        &mut self,
        socket: &UdpSocket,
        peer: &SocketAddr,
        outbound: &mut [u8; MAX_DATAGRAM_LEN],
        now_ms: u64,
    ) -> Result<(), String> {
        let (datagram_len, sequence) = encode_fault_frame(self.mode, self.request_id, outbound)?
            .ok_or_else(|| "run mode does not encode a protocol fault".to_owned())?;
        send_datagram(socket, peer, &outbound[..datagram_len], "fault")?;
        self.fault_injected = true;
        self.request_in_flight = true;
        self.request_sent_at_ms = now_ms;
        println!(
            "STARRY_T2N1_FAULT_SENT mode={} seq={} request={} elapsed_ms={now_ms}",
            self.mode.name(),
            sequence.get(),
            self.request_id
        );
        Ok(())
    }

    fn send_inference_control(
        &mut self,
        socket: &UdpSocket,
        peer: &SocketAddr,
        endpoint: &mut Endpoint,
        outbound: &mut [u8; MAX_DATAGRAM_LEN],
        now_ms: u64,
    ) -> Result<(), String> {
        let inference = match run_inference(self.mode) {
            Ok(inference) => inference,
            Err(reason) => {
                self.model_rejected = true;
                println!(
                    "TASK3_MODEL_REJECTED model=task3-temporal-cnn-m0 reason={reason:?} \
                     action=safe elapsed_ms={now_ms}"
                );
                println!("STARRY_T2N1_SAFE source=model reason={reason:?} elapsed_ms={now_ms}");
                return Ok(());
            }
        };
        println!(
            "TASK3_INFER model=cnn output={} correction={:.6} infer_us={} request={} \
             elapsed_ms={now_ms}",
            inference.control_value, inference.correction, inference.infer_us, self.request_id
        );
        println!(
            "TASK3_DETECTION model=cnn output={} source=guest-forward request={}",
            inference.control_value, self.request_id
        );

        let mut payload = [0u8; 12];
        let command = ControlMessage::new(
            ControlAction::SetOutput,
            inference.control_value,
            self.request_id,
        )
        .map_err(|error| format!("control construction error={error}"))?;
        let payload_len = command
            .encode(&mut payload)
            .map_err(|error| format!("control encoding error={error}"))?;
        let transmission = endpoint
            .queue_reliable(
                MessageKind::Control,
                &payload[..payload_len],
                now_ms,
                outbound,
            )
            .map_err(|error| format!("queue error={error}"))?;
        send_datagram(
            socket,
            peer,
            &outbound[..transmission.datagram_len()],
            "control",
        )?;
        self.request_in_flight = true;
        self.request_sent_at_ms = now_ms;
        self.status_received = false;
        println!(
            "STARRY_T2N1_CONTROL_SENT seq={} value={} request={} elapsed_ms={now_ms}",
            transmission.sequence().get(),
            inference.control_value,
            self.request_id
        );
        Ok(())
    }

    fn handle_receive_event(&mut self, event: ReceiveEvent<'_>, endpoint: &Endpoint, now_ms: u64) {
        match event {
            ReceiveEvent::Acknowledged { sequence } => {
                println!("STARRY_T2N1_ACK seq={}", sequence.get());
            }
            ReceiveEvent::Delivered { frame } if frame.kind() == MessageKind::Status => {
                match StatusMessage::decode(frame.payload()) {
                    Ok(status)
                        if self.request_in_flight
                            && status.last_control_request() == self.request_id =>
                    {
                        let rtt_ms = now_ms.saturating_sub(self.request_sent_at_ms);
                        self.request_in_flight = false;
                        self.status_received = true;
                        self.successful_cycles = self.successful_cycles.saturating_add(1);
                        self.next_send_at_ms = now_ms + CONTROL_INTERVAL_MS;
                        println!(
                            "STARRY_T2N1_STATUS_DELIVERED seq={} bytes={} request={} state={:?} \
                             value={} rtt_ms={rtt_ms}",
                            frame.sequence().get(),
                            frame.payload().len(),
                            status.last_control_request(),
                            status.state(),
                            status.value()
                        );
                        if self.recovery_pending {
                            println!(
                                "STARRY_T2N1_FAULT_RECOVERY_COMPLETE mode={} request={} \
                                 safe_observed=true recovered=true elapsed_ms={now_ms}",
                                self.mode.name(),
                                status.last_control_request()
                            );
                            self.recovery_pending = false;
                            self.protocol_safe_observed = false;
                        }
                        self.request_id = next_request_id(self.request_id);
                    }
                    Ok(status) => println!(
                        "STARRY_T2N1_STATUS_IGNORED seq={} request={} in_flight={}",
                        frame.sequence().get(),
                        status.last_control_request(),
                        self.request_in_flight
                    ),
                    Err(error) => println!("STARRY_T2N1_EVENT status_decode_error={error}"),
                }
            }
            ReceiveEvent::RemoteError { code, sequence } => println!(
                "STARRY_T2N1_REMOTE_ERROR code={code:?} sequence={} elapsed_ms={now_ms}",
                sequence.get()
            ),
            ReceiveEvent::OutOfOrder { sequence, expected } => println!(
                "STARRY_T2N1_EVENT out_of_order={} expected={}",
                sequence.get(),
                expected.get()
            ),
            ReceiveEvent::InvalidPayload { error } => {
                println!("STARRY_T2N1_EVENT invalid_payload={error}");
            }
            ReceiveEvent::Duplicate { sequence } => {
                println!("STARRY_T2N1_DUPLICATE seq={}", sequence.get());
            }
            ReceiveEvent::DuplicateAcknowledgement { sequence } => {
                println!("STARRY_T2N1_DUPLICATE_ACK seq={}", sequence.get());
            }
            ReceiveEvent::Rejected { error } => {
                println!("STARRY_T2N1_REJECTED error={error}");
            }
            ReceiveEvent::SessionMismatch => println!("STARRY_T2N1_REJECTED session_mismatch"),
            ReceiveEvent::Heartbeat { .. } | ReceiveEvent::Delivered { .. } => {}
        }
        self.report_first_success(endpoint);
    }

    fn enter_protocol_safe(&mut self, reason: &str, now_ms: u64) {
        self.protocol_safe_observed = true;
        if self.request_in_flight {
            self.request_id = next_request_id(self.request_id);
        }
        self.request_in_flight = false;
        self.pending_send = false;
        self.status_received = false;
        println!("STARRY_T2N1_SAFE source=protocol reason={reason} elapsed_ms={now_ms}");
    }

    fn recover(&mut self, now_ms: u64) {
        if self.protocol_safe_observed {
            self.recovery_pending = true;
        }
        self.request_in_flight = false;
        self.pending_send = false;
        self.status_received = false;
        self.next_send_at_ms = if self.recovery_pending {
            now_ms + CONTROL_INTERVAL_MS
        } else {
            now_ms
        };
        println!("STARRY_T2N1_RECOVERED state=Active elapsed_ms={now_ms}");
    }

    fn report_first_success(&mut self, endpoint: &Endpoint) {
        if !self.first_success_reported
            && self.successful_cycles >= 1
            && self.status_received
            && !endpoint.has_pending_frame()
            && endpoint.state() == EndpointState::Active
        {
            self.first_success_reported = true;
            println!("STARRY_T2N1_PASS");
        }
    }
}

fn run_inference(mode: RunMode) -> Result<InferenceOutput, InferenceRejection> {
    let state_history = [INITIAL_STATE];
    let output_history = [0];
    let features = build_features(
        &state_history,
        &output_history,
        CONTROL_TARGET,
        INITIAL_STATE,
        0,
    );
    let infer_started = Instant::now();
    let correction = forward(&features);
    let infer_us = infer_started.elapsed().as_micros();
    let candidate = if mode == RunMode::ModelRejected {
        f64::NAN
    } else {
        CONTROL_TARGET as f64 + correction * 1000.0
    };
    let control_value = validate_inference(candidate, infer_us)?;
    Ok(InferenceOutput {
        correction,
        control_value,
        infer_us,
    })
}

fn validate_inference(candidate: f64, infer_us: u128) -> Result<i32, InferenceRejection> {
    if !candidate.is_finite() {
        return Err(InferenceRejection::NonFiniteOutput);
    }
    if infer_us > MAX_INFERENCE_US {
        return Err(InferenceRejection::DeadlineExceeded);
    }
    let rounded = candidate.round();
    if !(0.0..=ControlMessage::MAX_OUTPUT_VALUE as f64).contains(&rounded) {
        return Err(InferenceRejection::OutputOutOfRange);
    }
    Ok(rounded as i32)
}

fn encode_fault_frame(
    mode: RunMode,
    request_id: u32,
    output: &mut [u8; MAX_DATAGRAM_LEN],
) -> Result<Option<(usize, SequenceNumber)>, String> {
    let sequence = match mode {
        RunMode::OutOfOrder => SequenceNumber::from_wire(2),
        RunMode::InvalidParameter => SequenceNumber::FIRST,
        RunMode::Normal | RunMode::ModelRejected => return Ok(None),
    };
    let mut payload = [0u8; 12];
    match mode {
        RunMode::OutOfOrder => {
            ControlMessage::new(ControlAction::SetOutput, CONTROL_TARGET, request_id)
                .map_err(|error| format!("fault control construction error={error}"))?
                .encode(&mut payload)
                .map_err(|error| format!("fault control encoding error={error}"))?;
        }
        RunMode::InvalidParameter => {
            payload[0] = ControlAction::SetOutput as u8;
            payload[4..8].copy_from_slice(&(ControlMessage::MAX_OUTPUT_VALUE + 1).to_be_bytes());
            payload[8..12].copy_from_slice(&request_id.to_be_bytes());
        }
        RunMode::Normal | RunMode::ModelRejected => unreachable!(),
    }
    let frame = Frame::reliable(MessageKind::Control, SESSION, sequence, &payload)
        .map_err(|error| format!("fault frame construction error={error}"))?;
    let datagram_len = frame
        .encode(output)
        .map_err(|error| format!("fault frame encoding error={error}"))?;
    Ok(Some((datagram_len, sequence)))
}

fn send_datagram(
    socket: &UdpSocket,
    destination: &SocketAddr,
    datagram: &[u8],
    operation: &str,
) -> Result<(), String> {
    let sent = socket
        .send_to(datagram, destination)
        .map_err(|error| format!("send {operation} error={error}"))?;
    if sent != datagram.len() {
        return Err(format!(
            "send {operation} short datagram sent={sent} expected={}",
            datagram.len()
        ));
    }
    Ok(())
}

const fn next_request_id(current: u32) -> u32 {
    let next = current.wrapping_add(1);
    if next == 0 { 1 } else { next }
}

fn elapsed_ms(started: &Instant) -> u64 {
    started.elapsed().as_millis() as u64
}

fn fail(message: &str) -> ! {
    println!("STARRY_T2N1_FAIL {message}");
    std::process::exit(1);
}

#[cfg(test)]
mod tests {
    use task2_net_protocol::PayloadError;

    use super::*;

    #[test]
    fn parses_supported_run_modes() {
        assert_eq!(RunMode::parse(None), Ok(RunMode::Normal));
        assert_eq!(RunMode::parse(Some("normal")), Ok(RunMode::Normal));
        assert_eq!(
            RunMode::parse(Some("out-of-order")),
            Ok(RunMode::OutOfOrder)
        );
        assert_eq!(
            RunMode::parse(Some("invalid-parameter")),
            Ok(RunMode::InvalidParameter)
        );
        assert_eq!(
            RunMode::parse(Some("model-rejected")),
            Ok(RunMode::ModelRejected)
        );
        assert!(RunMode::parse(Some("unknown")).is_err());
    }

    #[test]
    fn validates_finite_bounded_inference_before_control() {
        assert_eq!(validate_inference(417.2, 50_000), Ok(417));
        assert_eq!(
            validate_inference(f64::NAN, 50_000),
            Err(InferenceRejection::NonFiniteOutput)
        );
        assert_eq!(
            validate_inference(-1.0, 50_000),
            Err(InferenceRejection::OutputOutOfRange)
        );
        assert_eq!(
            validate_inference(1_001.0, 50_000),
            Err(InferenceRejection::OutputOutOfRange)
        );
        assert_eq!(
            validate_inference(417.0, MAX_INFERENCE_US + 1),
            Err(InferenceRejection::DeadlineExceeded)
        );
    }

    #[test]
    fn out_of_order_mode_emits_valid_sequence_two_control() {
        let mut datagram = [0; MAX_DATAGRAM_LEN];
        let (length, sequence) = encode_fault_frame(RunMode::OutOfOrder, 7, &mut datagram)
            .unwrap()
            .unwrap();
        let frame = Frame::parse(&datagram[..length]).unwrap();

        assert_eq!(sequence, SequenceNumber::from_wire(2));
        assert_eq!(frame.sequence(), SequenceNumber::from_wire(2));
        assert_eq!(frame.kind(), MessageKind::Control);
        assert_eq!(
            ControlMessage::decode(frame.payload())
                .unwrap()
                .request_id(),
            7
        );
    }

    #[test]
    fn invalid_parameter_mode_preserves_framing_and_crc() {
        let mut datagram = [0; MAX_DATAGRAM_LEN];
        let (length, sequence) = encode_fault_frame(RunMode::InvalidParameter, 9, &mut datagram)
            .unwrap()
            .unwrap();
        let frame = Frame::parse(&datagram[..length]).unwrap();

        assert_eq!(sequence, SequenceNumber::FIRST);
        assert_eq!(frame.sequence(), SequenceNumber::FIRST);
        assert_eq!(
            ControlMessage::decode(frame.payload()),
            Err(PayloadError::InvalidControlValue)
        );
    }

    #[test]
    fn safe_and_recovery_reset_application_request_lifecycle() {
        let mut control = ControlLoop::new(RunMode::Normal);
        control.request_id = 41;
        control.request_in_flight = true;
        control.pending_send = true;
        control.status_received = true;

        control.enter_protocol_safe("test", 100);

        assert_eq!(control.request_id, 42);
        assert!(!control.request_in_flight);
        assert!(!control.pending_send);
        assert!(!control.status_received);

        control.next_send_at_ms = 999;
        control.recover(123);

        assert_eq!(control.next_send_at_ms, 123 + CONTROL_INTERVAL_MS);
        assert!(!control.request_in_flight);
        assert!(!control.pending_send);
        assert!(control.protocol_safe_observed);
        assert!(control.recovery_pending);
    }
}
