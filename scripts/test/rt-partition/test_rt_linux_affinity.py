#!/usr/bin/env python3
"""Regression checks for the two-vCPU RT Linux workload topology."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNNER = (ROOT / "scripts/test/rt-partition/run-cyclictest.sh").read_text()
INIT = (ROOT / "scripts/test/rt-partition/rt-linux-init.sh").read_text()


class RtLinuxAffinityTest(unittest.TestCase):
    def test_rt_partition_only_silences_the_zephyr_host_cpu(self):
        stress_rt = RUNNER.split("stress-rt)", 1)[1].split(";;", 1)[0]
        self.assertIn('dedicated_cpus="1"', stress_rt)

    def test_matrix_has_a_single_variable_dedicated_virtualized_scenario(self):
        scenario = RUNNER.split("stress-dedicated)", 1)[1].split(";;", 1)[0]
        self.assertIn('dedicated_cpus="1"', scenario)
        self.assertIn('zephyr_guest_type="virtualized"', scenario)
        self.assertIn("stress-dedicated|stress-rt)", INIT)

    def test_runner_allows_tcg_time_for_zephyr_sampling(self):
        self.assertIn("zephyr_timeout=180", RUNNER)
        self.assertIn("expect ${zephyr_timeout} PERIODIC LATENCY COMPLETE", RUNNER)

    def test_all_formal_scenarios_budget_for_slow_tcg_guest_time(self):
        idle = RUNNER.split("idle)", 1)[1].split(";;", 1)[0]
        stress_noiso = RUNNER.split("stress-noiso)", 1)[1].split(";;", 1)[0]
        stress_rt = RUNNER.split("stress-rt)", 1)[1].split(";;", 1)[0]
        self.assertIn("runtime_scale=3", idle)
        self.assertIn("runtime_scale=3", stress_noiso)
        self.assertIn("runtime_scale=3", stress_rt)
        self.assertIn(
            "expected_wall_runtime_sec=$((expected_runtime_sec * runtime_scale))",
            RUNNER,
        )
        self.assertIn("experiment_timeout=$(( expected_wall_runtime_sec + 300 ))", RUNNER)

    def test_runner_prefers_per_scenario_calibration_over_fixed_default(self):
        self.assertIn("runtime-scales.env", RUNNER)
        self.assertIn("calibrated_scale", RUNNER)
        self.assertIn("runtime_scale_source", RUNNER)

    def test_runner_isolates_the_measurement_cpu(self):
        self.assertIn('rt_cpu="${RT_CPU:-1}"', RUNNER)
        self.assertIn('load_cpu=$((1 - rt_cpu))', RUNNER)
        self.assertRegex(RUNNER, r"isolcpus=\$\{rt_cpu\} nohz_full=\$\{rt_cpu\}")
        self.assertRegex(RUNNER, r"irqaffinity=\$\{load_cpu\}")
        self.assertRegex(RUNNER, r"rt_load_cpu=\$\{load_cpu\}")

    def test_guest_pins_stress_outside_the_measurement_cpu(self):
        self.assertIn('rt_load_cpu=*) load_cpu="${arg#rt_load_cpu=}"', INIT)
        self.assertIn('/bin/busybox taskset -c "$load_cpu" /bin/stress-ng', INIT)
        self.assertNotRegex(INIT, re.compile(r"stress-ng\s+--taskset"))

    def test_guest_moves_cyclictest_before_libnuma_starts(self):
        self.assertIn('all_cpus="0-$((cpu_total - 1))"', INIT)
        self.assertIn(
            '/bin/busybox taskset -c "$all_cpus" /bin/cyclictest -a "$cpu"',
            INIT,
        )

    def test_formal_runs_can_use_fixed_duration_instead_of_assumed_loop_rate(self):
        self.assertIn('duration_sec="${RT_DURATION_SEC:-0}"', RUNNER)
        self.assertIn("cyclictest_loops=0", RUNNER)
        self.assertIn("run_mode=duration", RUNNER)
        self.assertIn('rt_duration_sec=${duration_sec}', RUNNER)
        self.assertIn('-D "${duration_sec}s"', INIT)

    def test_duration_acceptance_uses_guest_uptime_not_runner_wall_time(self):
        self.assertIn(
            'echo "RT_CYCLICTEST_TIMING_START uptime_s=$start_uptime_s"',
            INIT,
        )
        self.assertIn(
            'echo "RT_CYCLICTEST_TIMING_END uptime_s=$end_uptime_s"',
            INIT,
        )
        self.assertIn(
            'guest_elapsed_s = end_uptime_s - start_uptime_s',
            RUNNER,
        )
        self.assertIn('minimum_guest_elapsed_s = Decimal(duration_sec) * Decimal("0.9")', RUNNER)
        self.assertNotIn('summary["total_samples"] * interval_us', RUNNER)
        self.assertNotIn("minimum_elapsed_ms = expected_runtime_sec * 900", RUNNER)

    def test_formal_runner_uses_progress_markers_and_a_no_progress_watchdog(self):
        self.assertIn('echo "RT_PROGRESS uptime_s=$progress_uptime_s"', INIT)
        self.assertIn("--progress-regex", RUNNER)
        self.assertIn("--progress-timeout", RUNNER)
        self.assertIn("RT_PROGRESS uptime_s=", RUNNER)

    def test_progress_watchdog_preserves_post_stall_forensics(self):
        self.assertIn('--qmp-sock "$qmp_sock"', RUNNER)
        self.assertIn('--forensics-dir "$out_dir/post-stall"', RUNNER)
        self.assertIn('post-stall/query-status.json', RUNNER)
        self.assertIn('post-stall/info-registers-2.json', RUNNER)

    def test_serial_log_records_host_timestamps(self):
        self.assertIn("--timestamp-lines", RUNNER)
        self.assertIn("host_monotonic_s=", RUNNER)

    def test_formal_metadata_records_that_realtime_trace_is_disabled(self):
        self.assertIn("realtime_trace=disabled", RUNNER)

    def test_default_histogram_bound_keeps_formal_samples_in_range(self):
        self.assertIn('maxlat_us="${RT_MAXLAT_US:-20000}"', RUNNER)

    def test_outer_timeout_covers_boot_and_all_script_phases(self):
        self.assertIn("minimum_outer_timeout=$((", RUNNER)
        self.assertIn("timeout_sec >= minimum_outer_timeout", RUNNER)

    def test_zephyr_sampling_starts_inside_the_linux_workload_window(self):
        linux_start = RUNNER.index("expect ${linux_start_timeout} RT_CYCLICTEST_START")
        zephyr_gate = RUNNER.index("send-until 60 0.5 g PERIODIC LATENCY START")
        zephyr_complete = RUNNER.index(
            "expect ${zephyr_timeout} PERIODIC LATENCY COMPLETE samples=300"
        )
        linux_complete = RUNNER.index(
            "expect ${experiment_timeout} RT_CYCLICTEST_COMPLETE"
        )
        self.assertLess(linux_start, zephyr_gate)
        self.assertLess(zephyr_gate, zephyr_complete)
        self.assertLess(zephyr_complete, linux_complete)
        self.assertIn('zephyr_start_gated="$(sed -n', RUNNER)
        self.assertIn('[[ "$zephyr_start_gated" == "1" ]]', RUNNER)
        self.assertIn("send-until 60 0.5 g PERIODIC LATENCY START", RUNNER)

    def test_vmexit_snapshots_bound_the_zephyr_sampling_window(self):
        self.assertIn('expected at least three vmexit snapshots', RUNNER)
        self.assertIn('vmexit-zephyr-after.txt', RUNNER)
        zephyr_complete = RUNNER.index(
            "expect ${zephyr_timeout} PERIODIC LATENCY COMPLETE samples=300"
        )
        middle_snapshot = RUNNER.index("cmd vmexit stat", zephyr_complete)
        linux_attach = RUNNER.index("cmd vm console 1", middle_snapshot)
        self.assertLess(zephyr_complete, middle_snapshot)
        self.assertLess(middle_snapshot, linux_attach)

    def test_dedicated_scenarios_require_zero_host_ticks_on_pcpu1(self):
        self.assertIn("host-periodic-ticks.csv", RUNNER)
        self.assertIn("--require-zero-cpu 1", RUNNER)
        self.assertIn('stress-dedicated|stress-rt)', RUNNER)


if __name__ == "__main__":
    unittest.main()
