#!/usr/bin/env python3
"""Drive the QEMU serial console of an Axvisor run.

Connects to the serial UNIX socket, tees all console output to a log file and
stdout, and executes a small step script:

    sleep <seconds>            wait before the next step
    raw <python-bytes>         write raw bytes (e.g. raw \\x18h for Ctrl+X h)
    cmd <text>                 write text followed by a newline (shell command)
    expect <seconds> <regex>   wait until the regex appears in the output
    attach <vm_id>             switch the attached guest console to <vm_id>
    detach                     return from the guest console to the shell
    dump-pcap <prefix>         stream `virtnet capture dump` and write
                               <prefix>.vm1.pcap / <prefix>.vm2.pcap
    hold <seconds>             keep the connection open and keep reading

Example:
    serial_console.py sock log --script steps.txt
"""

import argparse
import re
import socket
import struct
import sys
import time

DUMP_BEGIN = "CAPDUMP_BEGIN"
DUMP_END = "CAPDUMP_END"

PCAP_GLOBAL_HEADER = bytes.fromhex(
    "d4c3b2a1"  # magic, little-endian
    "02000400"  # version 2.4
    "00000000"  # thiszone
    "00000000"  # sigfigs
    "ffff0000"  # snaplen 65535
    "01000000"  # linktype Ethernet
)


class ConsoleDriver:
    def __init__(self, sock_path: str, log_path: str):
        deadline = time.time() + 120
        self.conn = None
        while time.time() < deadline:
            try:
                conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                conn.settimeout(0.5)
                conn.connect(sock_path)
                self.conn = conn
                break
            except (FileNotFoundError, ConnectionRefusedError, OSError):
                time.sleep(2)
        if self.conn is None:
            raise SystemExit(f"error: serial socket {sock_path} never appeared")
        self.log_file = open(log_path, "a", encoding="utf-8", errors="replace")
        self.tail = b""
        self.dump_lines = []
        self.dumping = False
        self.last_vm = None
        self.attached = False
        self.closed = False

    def poll_reads(self) -> None:
        budget = time.monotonic() + 0.25
        while time.monotonic() < budget:
            try:
                data = self.conn.recv(65536)
            except socket.timeout:
                return
            except OSError:
                self.closed = True
                return
            if not data:
                self.closed = True
                return
            text = data.decode("utf-8", errors="replace")
            sys.stdout.write(text)
            sys.stdout.flush()
            self.log_file.write(text)
            self.log_file.flush()
            if self.dumping:
                self.dump_lines.append(text)
            self.tail = (self.tail + data)[-1_000_000:]
            match = re.search(
                r"\[Axvisor\] (attached|detached) VM\[(\d+)\]", text
            )
            if match:
                self.attached = match.group(1) == "attached"
                self.last_vm = int(match.group(2))

    def wait_for(self, pattern: str, seconds: float) -> bool:
        end = time.time() + seconds
        while time.time() < end and not self.closed:
            self.poll_reads()
            if re.search(pattern, self.tail.decode("utf-8", errors="replace")):
                return True
            time.sleep(0.3)
        return False

    def hold(self, seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end and not self.closed:
            self.poll_reads()
            time.sleep(0.3)

    def attach(self, vm_id: int) -> None:
        for _ in range(4):
            if self.attached and self.last_vm == vm_id:
                return
            self.conn.sendall(b"\x18]")
            deadline = time.time() + 2
            while time.time() < deadline:
                self.poll_reads()
                if self.attached and self.last_vm is not None:
                    break
        if not (self.attached and self.last_vm == vm_id):
            print(
                f"warning: could not confirm attachment to VM {vm_id}",
                file=sys.stderr,
            )

    def dump_pcap(self, prefix: str) -> None:
        self.dump_lines = []
        self.dumping = True
        self.conn.sendall(b"virtnet capture dump\n")
        deadline = time.time() + 60
        got_end = False
        while time.time() < deadline and not self.closed:
            self.poll_reads()
            joined = "".join(self.dump_lines)
            if DUMP_END in joined:
                got_end = True
                break
            time.sleep(0.3)
        self.dumping = False
        if not got_end:
            print("error: capture dump did not complete", file=sys.stderr)
            return
        joined = "".join(self.dump_lines)
        begin = joined.find(DUMP_BEGIN)
        end = joined.find(DUMP_END)
        body = joined[begin + len(DUMP_BEGIN):end]
        frames = {1: [], 2: []}
        for line in body.splitlines():
            match = re.match(r"CAPTURE (\d+) (\d+) ([0-9a-f]+)", line.strip())
            if not match:
                continue
            vm = int(match.group(1))
            nanos = int(match.group(2))
            frame = bytes.fromhex(match.group(3))
            frames.setdefault(vm, []).append((nanos, frame))
        for vm, records in sorted(frames.items()):
            with open(f"{prefix}.vm{vm}.pcap", "wb") as pcap_file:
                pcap_file.write(PCAP_GLOBAL_HEADER)
                for nanos, frame in records:
                    seconds = nanos // 1_000_000_000
                    micros = (nanos // 1_000) % 1_000_000
                    length = len(frame)
                    pcap_file.write(
                        struct.pack("<IIII", seconds, micros, length, length)
                    )
                    pcap_file.write(frame)
            print(f"pcap: wrote {len(records)} frames to {prefix}.vm{vm}.pcap")
        self.dump_lines = []


    def qmp_quit(self, qmp_sock: str) -> None:
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                qmp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                qmp.settimeout(3)
                qmp.connect(qmp_sock)
                qmp.recv(4096)
                qmp.sendall(b'{"execute":"qmp_capabilities"}\n')
                time.sleep(0.5)
                qmp.recv(4096)
                qmp.sendall(b'{"execute":"quit"}\n')
                time.sleep(1)
                qmp.close()
                return
            except (FileNotFoundError, ConnectionRefusedError, OSError):
                time.sleep(2)
        print("warning: could not quit QEMU over QMP", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sock", help="serial UNIX socket path")
    parser.add_argument("log", help="console log file to append to")
    parser.add_argument("--script", help="step script file")
    parser.add_argument("--verbose", action="store_true", help="log step progress to stderr")
    args = parser.parse_args()

    driver = ConsoleDriver(args.sock, args.log)

    steps = []
    if args.script:
        with open(args.script, encoding="utf-8") as script_file:
            for line in script_file:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                steps.append(line)

    for step in steps:
        if driver.closed:
            break
        if args.verbose:
            print(f"[driver] step: {step!r}", file=sys.stderr, flush=True)
        if step.startswith("sleep "):
            driver.hold(float(step.split(" ", 1)[1]))
        elif step.startswith("hold "):
            driver.hold(float(step.split(" ", 1)[1]))
        elif step.startswith("raw "):
            payload = step.split(" ", 1)[1]
            encoded = payload.encode().decode("unicode_escape").encode("latin-1")
            driver.conn.sendall(encoded)
            time.sleep(0.3)
        elif step.startswith("cmd "):
            driver.conn.sendall((step.split(" ", 1)[1] + "\n").encode())
            time.sleep(0.3)
        elif step.startswith("expect "):
            _, seconds, pattern = step.split(" ", 2)
            if not driver.wait_for(pattern, float(seconds)):
                print(
                    f"error: expected pattern {pattern!r} did not appear",
                    file=sys.stderr,
                )
                return 2
        elif step.startswith("attach "):
            driver.attach(int(step.split(" ", 1)[1]))
        elif step == "detach":
            driver.conn.sendall(b"\x18h")
            time.sleep(0.3)
        elif step.startswith("dump-pcap "):
            driver.dump_pcap(step.split(" ", 1)[1])
        elif step.startswith("qmp-quit "):
            driver.qmp_quit(step.split(" ", 1)[1])
        else:
            print(f"error: unknown step {step!r}", file=sys.stderr)
            return 3

    driver.hold(2)
    driver.conn.close()
    driver.log_file.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
