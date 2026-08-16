#!/usr/bin/env python3
"""Regression tests for complete cyclictest histogram accounting."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/test/rt-partition/cyclictest-hist-to-csv.py"


class CyclictestHistogramTest(unittest.TestCase):
    def test_overflows_are_counted_in_the_summary(self):
        log = """\
[VM 1] # Histogram
[VM 1] 000001 000002
[VM 1] 000002 000001
[VM 1] # Min Latencies: 00001
[VM 1] # Avg Latencies: 00002
[VM 1] # Max Latencies: 00500
[VM 1] # Histogram Overflows: 00002
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            log_path = temp / "run.log"
            csv_path = temp / "histogram.csv"
            summary_path = temp / "summary.txt"
            log_path.write_text(log)

            subprocess.run(
                [sys.executable, str(SCRIPT), str(log_path), str(csv_path), str(summary_path)],
                check=True,
                text=True,
                capture_output=True,
            )

            self.assertEqual(csv_path.read_text(), "bucket_us,count\n1,2\n2,1\n")
            summary = summary_path.read_text()
            self.assertIn("bucket_samples=3\n", summary)
            self.assertIn("overflow_samples=2\n", summary)
            self.assertIn("total_samples=5\n", summary)
            self.assertIn("max_latency_us=500\n", summary)

    def test_host_timestamp_prefix_does_not_hide_histogram_markers(self):
        log = """\
[host_monotonic_s=10.000000] [VM 1] # Histogram
[host_monotonic_s=10.100000] [VM 1] 000001 000002
[host_monotonic_s=10.200000] [VM 1] # Min Latencies: 00001
[host_monotonic_s=10.300000] [VM 1] # Avg Latencies: 00002
[host_monotonic_s=10.400000] [VM 1] # Max Latencies: 00003
[host_monotonic_s=10.500000] [VM 1] # Histogram Overflows: 00000
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            log_path = temp / "run.log"
            csv_path = temp / "histogram.csv"
            summary_path = temp / "summary.txt"
            log_path.write_text(log)

            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(log_path), str(csv_path), str(summary_path)],
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(csv_path.read_text(), "bucket_us,count\n1,2\n")


if __name__ == "__main__":
    unittest.main()
