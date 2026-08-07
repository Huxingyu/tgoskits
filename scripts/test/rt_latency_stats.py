#!/usr/bin/env python3
"""Summarize periodic real-time samples from CSV or standard input.

Expected columns:
    sequence,timestamp_ns,deadline_ns,actual_ns,jitter_ns

The sampler's ``deadline_ns`` column is the scheduled release target. A
deadline miss can only be computed when the caller supplies a relative
deadline with ``--relative-deadline-ns``; otherwise the result is reported as
unavailable instead of treating every positive jitter sample as a miss.
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path


def percentile(values: list[int], fraction: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def read_samples(
    stream, relative_deadline_ns: int | None = None
) -> tuple[list[int], int | None]:
    reader = csv.DictReader(
        line for line in stream if line.strip() and not line.lstrip().startswith("#")
    )
    required = {"jitter_ns", "deadline_ns", "actual_ns"}
    missing = required - set(reader.fieldnames or ())
    if missing:
        raise ValueError(f"missing columns: {', '.join(sorted(missing))}")

    if relative_deadline_ns is not None and relative_deadline_ns < 0:
        raise ValueError("relative deadline must be non-negative")

    jitter: list[int] = []
    deadline_misses = 0 if relative_deadline_ns is not None else None
    for row in reader:
        jitter_ns = int(row["jitter_ns"])
        jitter.append(jitter_ns)
        if (
            relative_deadline_ns is not None
            and int(row["actual_ns"])
            > int(row["deadline_ns"]) + relative_deadline_ns
        ):
            deadline_misses += 1
    return jitter, deadline_misses


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", nargs="?", type=Path, help="CSV file; read stdin when omitted")
    parser.add_argument(
        "--relative-deadline-ns",
        type=int,
        help="relative deadline added to each release target for overrun accounting",
    )
    args = parser.parse_args()

    try:
        if args.csv is None:
            samples, misses = read_samples(sys.stdin)
        else:
            with args.csv.open(newline="") as stream:
                samples, misses = read_samples(
                    stream, relative_deadline_ns=args.relative_deadline_ns
                )
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if not samples:
        print("samples=0")
        return 0

    print(f"samples={len(samples)}")
    print(f"mean_jitter_ns={sum(samples) / len(samples):.2f}")
    print(f"p99_jitter_ns={percentile(samples, 0.99)}")
    print(f"p99_9_jitter_ns={percentile(samples, 0.999)}")
    print(f"max_jitter_ns={max(samples)}")
    if misses is None:
        print("deadline_misses=unavailable")
    else:
        print(f"deadline_misses={misses}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
