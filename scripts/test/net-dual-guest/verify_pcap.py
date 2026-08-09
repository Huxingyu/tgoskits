#!/usr/bin/env python3
"""Verify task-2 pcap evidence with no external dependencies.

Usage:
  python3 verify_pcap.py linux.pcap rtos.pcap \
      --tag probe [--port 4242] [--src 10.0.42.1] [--dst 10.0.42.2] \
      [--min-udp 1]

Checks:
  1. Both pcaps are non-empty Ethernet captures.
  2. Both contain UDP traffic and at least one payload tagged with --tag.
  3. Expected src/dst IPs appear in at least one UDP packet (when given).
  4. PING/ACK counts are consistent between the two sides (mirror check).
"""

import argparse
import struct
import sys
from collections import Counter


ETH_P_IPV4 = 0x0800
ETH_P_ARP = 0x0806
IPPROTO_UDP = 17


def read_pcap(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 24:
        raise ValueError(f"{path}: too small for a pcap global header")
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian = "<"
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian = ">"
    else:
        raise ValueError(f"{path}: not a pcap file (bad magic {magic!r})")

    _, _, _, _, _, network = struct.unpack(endian + "HHIIII", data[0:24])
    packets = []
    off = 24
    while off + 16 <= len(data):
        ts_sec, ts_usec, incl_len, orig_len = struct.unpack(
            endian + "IIII", data[off : off + 16]
        )
        off += 16
        if incl_len > len(data) - off:
            raise ValueError(f"{path}: truncated packet at offset {off - 16}")
        packets.append(
            {
                "ts": ts_sec + ts_usec / 1_000_000.0,
                "data": data[off : off + incl_len],
            }
        )
        off += incl_len
    return network, packets


def parse_ethernet(pkt):
    if len(pkt) < 14:
        return None
    dst = pkt[0:6].hex(":")
    src = pkt[6:12].hex(":")
    ethertype = int.from_bytes(pkt[12:14], "big")
    return {"dst": dst, "src": src, "ethertype": ethertype, "payload": pkt[14:]}


def parse_ipv4(payload):
    if len(payload) < 20 or (payload[0] >> 4) != 4:
        return None
    ihl = (payload[0] & 0x0F) * 4
    if ihl < 20 or len(payload) < ihl:
        return None
    protocol = payload[9]
    src = ".".join(str(b) for b in payload[12:16])
    dst = ".".join(str(b) for b in payload[16:20])
    return {
        "protocol": protocol,
        "src": src,
        "dst": dst,
        "payload": payload[ihl:],
    }


def parse_udp(payload):
    if len(payload) < 8:
        return None
    sport = int.from_bytes(payload[0:2], "big")
    dport = int.from_bytes(payload[2:4], "big")
    return {
        "sport": sport,
        "dport": dport,
        "payload": payload[8:],
    }


def analyze(path, tag):
    network, packets = read_pcap(path)
    stats = Counter(
        {
            "packets": len(packets),
            "eth": 0,
            "ipv4": 0,
            "arp": 0,
            "udp": 0,
            "ping": 0,
            "ack": 0,
            "tagged": 0,
        }
    )
    udp_addrs = Counter()
    udp_ports = Counter()
    for pkt in packets:
        eth = parse_ethernet(pkt["data"])
        if eth is None:
            continue
        stats["eth"] += 1
        if eth["ethertype"] == ETH_P_ARP:
            stats["arp"] += 1
            continue
        if eth["ethertype"] != ETH_P_IPV4:
            continue
        ip = parse_ipv4(eth["payload"])
        if ip is None:
            continue
        stats["ipv4"] += 1
        if ip["protocol"] != IPPROTO_UDP:
            continue
        udp = parse_udp(ip["payload"])
        if udp is None:
            continue
        stats["udp"] += 1
        udp_addrs[(ip["src"], ip["dst"])] += 1
        udp_ports[(udp["sport"], udp["dport"])] += 1
        body = udp["payload"].decode("latin-1", errors="replace")
        if body.startswith("PING "):
            stats["ping"] += 1
        elif body.startswith("ACK "):
            stats["ack"] += 1
        if tag and tag in body:
            stats["tagged"] += 1

    return {
        "path": path,
        "network": network,
        "stats": stats,
        "udp_addrs": udp_addrs,
        "udp_ports": udp_ports,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pcaps", nargs=2)
    parser.add_argument("--tag", default="probe")
    parser.add_argument("--port", type=int)
    parser.add_argument("--src")
    parser.add_argument("--dst")
    parser.add_argument("--min-udp", type=int, default=1)
    args = parser.parse_args()

    left, right = (analyze(path, args.tag) for path in args.pcaps)
    failures = []

    for item in (left, right):
        if item["network"] != 1:
            failures.append(f"{item['path']}: link type {item['network']}, expected Ethernet(1)")
        if item["stats"]["packets"] == 0:
            failures.append(f"{item['path']}: no packets captured")
        if item["stats"]["udp"] < args.min_udp:
            failures.append(
                f"{item['path']}: only {item['stats']['udp']} UDP packets, "
                f"expected >= {args.min_udp}"
            )
        if item["stats"]["tagged"] == 0:
            failures.append(f"{item['path']}: no payload tagged with {args.tag!r}")

    if args.port:
        for item in (left, right):
            ports = {p for p in item["udp_ports"] if args.port in p}
            if not ports:
                failures.append(f"{item['path']}: no UDP traffic on port {args.port}")

    if args.src or args.dst:
        for item in (left, right):
            pairs = set(item["udp_addrs"])
            if args.src and not any(src == args.src for src, _ in pairs):
                failures.append(f"{item['path']}: src {args.src} not seen in UDP")
            if args.dst and not any(dst == args.dst for _, dst in pairs):
                failures.append(f"{item['path']}: dst {args.dst} not seen in UDP")

    # Mirror check: the same traffic is observable from both sides.
    for key in ("ping", "ack"):
        a = left["stats"][key]
        b = right["stats"][key]
        if max(a, b) > 0 and abs(a - b) > max(1, max(a, b) // 10):
            failures.append(f"mirror mismatch for {key}: {a} vs {b}")

    print(f"left : {left['path']}")
    print(f"  packets={left['stats']['packets']} eth={left['stats']['eth']} "
          f"ipv4={left['stats']['ipv4']} arp={left['stats']['arp']} "
          f"udp={left['stats']['udp']} ping={left['stats']['ping']} "
          f"ack={left['stats']['ack']} tagged={left['stats']['tagged']}")
    print(f"right: {right['path']}")
    print(f"  packets={right['stats']['packets']} eth={right['stats']['eth']} "
          f"ipv4={right['stats']['ipv4']} arp={right['stats']['arp']} "
          f"udp={right['stats']['udp']} ping={right['stats']['ping']} "
          f"ack={right['stats']['ack']} tagged={right['stats']['tagged']}")

    if failures:
        print("\nFAIL:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nPASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
