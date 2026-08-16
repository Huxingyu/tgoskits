#!/usr/bin/env python3
"""Regression tests for repeated RT run comparison summaries."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/test/rt-partition/compare-rt-runs.py"


def write_run(path: Path, commit: str, p99_ns: int, misses: int) -> None:
    path.mkdir(parents=True)
    (path / "meta.txt").write_text(f"git_commit={commit}\n")
    (path / "zephyr-stats.txt").write_text(
        "samples=300\n"
        f"mean_jitter_ns={p99_ns / 2:.2f}\n"
        f"p99_jitter_ns={p99_ns}\n"
        f"p99_9_jitter_ns={p99_ns + 100}\n"
        f"max_jitter_ns={p99_ns + 200}\n"
        "deadline_tolerance_ns=1000000\n"
        f"deadline_misses_tolerance={misses}\n"
    )


class CompareRtRunsTest(unittest.TestCase):
    def test_reports_group_ranges_and_paired_p99_improvement(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            baseline = [root / f"baseline-{index}" for index in range(3)]
            modified = [root / f"modified-{index}" for index in range(3)]
            for path, value in zip(baseline, (10_000_000, 12_000_000, 11_000_000)):
                write_run(path, "baseline-sha", value, 200)
            for path, value in zip(modified, (800_000, 900_000, 1_000_000)):
                write_run(path, "modified-sha", value, 0)
            output = root / "comparison.txt"

            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--baseline-label",
                    "upstream-dev",
                    "--baseline",
                    *(str(path) for path in baseline),
                    "--modified-label",
                    "rt-partition",
                    "--modified",
                    *(str(path) for path in modified),
                    "--output",
                    str(output),
                ],
                check=True,
                text=True,
                capture_output=True,
            )

            summary = output.read_text()
            self.assertIn("baseline_git_commit=baseline-sha\n", summary)
            self.assertIn("modified_git_commit=modified-sha\n", summary)
            self.assertIn("baseline_p99_jitter_ns_median=11000000\n", summary)
            self.assertIn("modified_p99_jitter_ns_median=900000\n", summary)
            self.assertIn("p99_improvement_ratio=12.222222\n", summary)
            self.assertIn("paired_p99_improvement_ratio_median=12.500000\n", summary)

    def test_rejects_mixed_commits_within_one_group(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            baseline_a = root / "baseline-a"
            baseline_b = root / "baseline-b"
            modified = root / "modified"
            write_run(baseline_a, "sha-a", 10_000_000, 1)
            write_run(baseline_b, "sha-b", 10_000_000, 1)
            write_run(modified, "sha-c", 1_000_000, 0)

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--baseline",
                    str(baseline_a),
                    str(baseline_b),
                    "--modified",
                    str(modified),
                ],
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("baseline runs use multiple git commits", result.stderr)


if __name__ == "__main__":
    unittest.main()
