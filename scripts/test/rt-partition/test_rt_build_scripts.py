#!/usr/bin/env python3
"""Regression checks for reproducible RT guest build paths."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
BUILD_ZEPHYR = (ROOT / "scripts/test/rt-partition/build-zephyr-periodic.sh").read_text()
NATIVE_RUNNER_PATH = ROOT / "scripts/test/rt-partition/run-native-zephyr.sh"
MATRIX_RUNNER = (ROOT / "scripts/test/rt-partition/run-cyclictest.sh").read_text()
ZEPHYR_MAIN = (ROOT / "scripts/test/zephyr-periodic/src/main.c").read_text()


class RtBuildScriptsTest(unittest.TestCase):
    def test_zephyr_build_normalizes_caller_supplied_relative_paths(self):
        self.assertIn('out_dir="$(realpath -m "$out_dir")"', BUILD_ZEPHYR)
        self.assertIn('build_dir="$(realpath -m "$build_dir")"', BUILD_ZEPHYR)

    def test_zephyr_build_records_the_uart_start_gate(self):
        self.assertIn('start_gated="${ZEPHYR_START_GATED:-1}"', BUILD_ZEPHYR)
        self.assertIn('-DRT_START_GATED="$start_gated"', BUILD_ZEPHYR)
        self.assertIn('start_delay_ms="${ZEPHYR_START_DELAY_MS:-0}"', BUILD_ZEPHYR)
        self.assertIn('-DRT_START_DELAY_MS="$start_delay_ms"', BUILD_ZEPHYR)
        self.assertIn("start_gated=%s", BUILD_ZEPHYR)
        self.assertIn("PERIODIC LATENCY READY", ZEPHYR_MAIN)
        self.assertIn("k_sleep(K_MSEC(1));", ZEPHYR_MAIN)
        self.assertIn("PERIODIC LATENCY SETTLE", ZEPHYR_MAIN)
        self.assertIn("uart_poll_in", ZEPHYR_MAIN)

    def test_native_zephyr_runner_archives_complete_evidence(self):
        runner = NATIVE_RUNNER_PATH.read_text()
        self.assertIn("PERIODIC LATENCY COMPLETE samples=300", runner)
        self.assertIn("expected 300 native Zephyr samples", runner)
        self.assertIn("rt_latency_stats.py", runner)
        self.assertIn("sha256sums", runner)
        self.assertIn("-cpu cortex-a72", runner)
        self.assertNotIn("-icount", runner)
        self.assertIn("timing_model=wall-clock TCG", runner)
        self.assertIn("(( linked_base == 0x40000000 ))", runner)
        self.assertIn('input_bin="${input_dir}/zephyr-periodic.bin"', runner)
        self.assertIn('actual_sha="$(sha256sum "$input_bin"', runner)
        self.assertIn('[[ "$start_gated" == "0" ]]', runner)

    def test_zephyr_sampler_defers_console_output_until_sampling_finishes(self):
        main_body = ZEPHYR_MAIN.split("int main(void)", 1)[1]
        sample_loop = main_body.split(
            "for (int64_t sequence = 0; sequence < SAMPLE_COUNT; sequence++) {", 1
        )[1].split("\n\t}", 1)[0]
        self.assertNotIn("printk", sample_loop)
        self.assertIn("static struct latency_sample samples[SAMPLE_COUNT]", ZEPHYR_MAIN)
        self.assertIn("print_samples(samples)", ZEPHYR_MAIN)

    def test_matrix_runner_hashes_archived_build_inputs(self):
        self.assertIn('cp "$work/linux-qemu" "$out_dir/"', MATRIX_RUNNER)
        self.assertIn('cp "$work/rt-linux-initramfs.cpio.gz" "$out_dir/"', MATRIX_RUNNER)
        self.assertIn('cp "$work/zephyr-periodic.bin" "$out_dir/"', MATRIX_RUNNER)
        self.assertIn('cp "$axvisor_bin" "$out_dir/"', MATRIX_RUNNER)
        hash_block = MATRIX_RUNNER.rsplit("sha256sum", 1)[1]
        self.assertNotIn("$work", hash_block)
        self.assertNotIn("$axvisor_bin", hash_block)

    def test_matrix_runner_allows_stress_results_to_drain_after_cyclictest(self):
        self.assertIn(
            'result_drain_timeout="${RT_RESULT_DRAIN_TIMEOUT_SEC:-180}"',
            MATRIX_RUNNER,
        )
        self.assertIn(
            "expect ${result_drain_timeout} RT_INIT_DONE scenario=${scenario}",
            MATRIX_RUNNER,
        )
        self.assertNotIn("expect 30 RT_INIT_DONE", MATRIX_RUNNER)


if __name__ == "__main__":
    unittest.main()
