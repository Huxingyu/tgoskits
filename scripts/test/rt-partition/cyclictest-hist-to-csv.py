#!/usr/bin/env python3
"""Extract the cyclictest histogram from a console log and write CSV.

Input: a serial log that contains the quiet cyclictest output:
    # Histogram
    ...
    # Histogram Bucket Latencies (us):
    0 5 3 0 0 ...

Output CSV columns: bucket_us,count

Usage: cyclictest-hist-to-csv.py <log> <out.csv>
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def extract_histogram(text: str) -> list[tuple[int, int]]:
    marker = "# Histogram Bucket Latencies (us):"
    idx = text.find(marker)
    if idx < 0:
        raise ValueError("cyclictest histogram marker not found in log")
    line_start = text.find("\n", idx) + 1
    line_end = text.find("\n", line_start)
    line = text[line_start:line_end].strip()
    counts = line.split()
    return [(bucket, int(count)) for bucket, count in enumerate(counts)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args()

    try:
        buckets = extract_histogram(args.log.read_text())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    with args.out.open("w", newline="") as stream:
        stream.write("bucket_us,count\n")
        for bucket, count in buckets:
            stream.write(f"{bucket},{count}\n")
    total = sum(count for _, count in buckets)
    print(f"buckets={len(buckets)} total_samples={total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
