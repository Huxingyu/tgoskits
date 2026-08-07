import importlib.util
import pathlib
import unittest


SCRIPT_PATH = pathlib.Path(__file__).with_name("rt_latency_stats.py")
SPEC = importlib.util.spec_from_file_location("rt_latency_stats", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class RtLatencyStatsTest(unittest.TestCase):
    def test_deadline_overrun_uses_relative_deadline(self):
        csv_data = (
            "sequence,timestamp_ns,deadline_ns,actual_ns,jitter_ns\n"
            "0,100,100,105,5\n"
            "1,200,200,220,20\n"
        )

        jitter, misses = MODULE.read_samples(
            csv_data.splitlines(True), relative_deadline_ns=10
        )

        self.assertEqual(jitter, [5, 20])
        self.assertEqual(misses, 1)

    def test_deadline_misses_are_unavailable_without_relative_deadline(self):
        csv_data = (
            "sequence,timestamp_ns,deadline_ns,actual_ns,jitter_ns\n"
            "0,100,100,105,5\n"
        )

        _, misses = MODULE.read_samples(csv_data.splitlines(True))

        self.assertIsNone(misses)


if __name__ == "__main__":
    unittest.main()
