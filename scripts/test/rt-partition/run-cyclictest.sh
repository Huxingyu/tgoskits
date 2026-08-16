#!/usr/bin/env bash
set -euo pipefail

# Build and run one Task1 matrix scenario with scenario-specific VM configs.
# Evidence is accepted only when both guests complete, cyclictest emits a real
# histogram, three vmexit/tick snapshots exist, and the requested duration is met.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scenario="${RT_SCENARIO:-idle}"
loops="${RT_LOOPS:-1800000}"
duration_sec="${RT_DURATION_SEC:-0}"
interval_us="${RT_INTERVAL_US:-1000}"
maxlat_us="${RT_MAXLAT_US:-20000}"
priority="${RT_PRIORITY:-90}"
rt_cpu="${RT_CPU:-1}"
start_delay_sec="${RT_START_DELAY_SEC:-25}"
result_drain_timeout="${RT_RESULT_DRAIN_TIMEOUT_SEC:-180}"

case "$scenario" in
    idle)
        dedicated_cpus=""
        zephyr_guest_type="virtualized"
        runtime_scale=3
        ;;
    stress-noiso)
        dedicated_cpus=""
        zephyr_guest_type="virtualized"
        runtime_scale=3
        ;;
    stress-rt)
        dedicated_cpus="1"
        zephyr_guest_type="passthrough"
        runtime_scale=3
        ;;
    stress-dedicated)
        dedicated_cpus="1"
        zephyr_guest_type="virtualized"
        runtime_scale=3
        ;;
    *)
        printf 'error: RT_SCENARIO must be idle, stress-noiso, stress-dedicated, or stress-rt\n' >&2
        exit 2
        ;;
esac
calibration_file="${RT_CALIBRATION_FILE:-${repo_root}/results/task1/calibration/runtime-scales.env}"
calibrated_scale=""
if [[ -f "$calibration_file" ]]; then
    calibrated_scale="$(sed -n "s/^${scenario}=//p" "$calibration_file" | tail -n 1)"
fi
if [[ -n "${RT_TCG_RUNTIME_SCALE:-}" ]]; then
    runtime_scale="$RT_TCG_RUNTIME_SCALE"
    runtime_scale_source="environment"
elif [[ -n "$calibrated_scale" ]]; then
    runtime_scale="$calibrated_scale"
    runtime_scale_source="$calibration_file"
else
    runtime_scale_source="default"
fi
host_tick_args=()
case "$scenario" in
    stress-dedicated|stress-rt)
        host_tick_args=(--require-zero-cpu 1)
        ;;
esac

for value in "$loops" "$duration_sec" "$interval_us" "$maxlat_us" "$priority" "$rt_cpu" "$start_delay_sec" "$runtime_scale" "$result_drain_timeout"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { printf 'error: numeric RT option is invalid: %s\n' "$value" >&2; exit 2; }
done
(( interval_us > 0 && runtime_scale > 0 && result_drain_timeout > 0 )) || {
    printf 'error: interval, runtime scale, and result drain timeout must be positive\n' >&2
    exit 2
}
(( rt_cpu <= 1 )) || { printf 'error: RT_CPU must be 0 or 1 for the two-vCPU Linux guest\n' >&2; exit 2; }
load_cpu=$((1 - rt_cpu))

if (( duration_sec > 0 )); then
    run_mode=duration
    cyclictest_loops=0
    expected_runtime_sec=$duration_sec
else
    (( loops > 0 )) || { printf 'error: RT_LOOPS must be positive in loop mode\n' >&2; exit 2; }
    run_mode=loops
    cyclictest_loops=$loops
    expected_runtime_sec=$(( (loops * interval_us + 999999) / 1000000 ))
fi
expected_wall_runtime_sec=$((expected_runtime_sec * runtime_scale))
experiment_timeout=$(( expected_wall_runtime_sec + 300 ))
zephyr_timeout=180
linux_start_timeout=300
serial_socket_timeout=600
progress_timeout="${RT_PROGRESS_TIMEOUT_SEC:-300}"
minimum_outer_timeout=$((
    serial_socket_timeout + 120 + linux_start_timeout + 60 + 10 + 2 + 10 + 10 +
    zephyr_timeout + 10 + 2 + 10 + 1 + experiment_timeout + result_drain_timeout +
    30 + 2 + 30 + 60
))
timeout_sec="${RT_TIMEOUT_SEC:-$minimum_outer_timeout}"
(( timeout_sec >= minimum_outer_timeout )) || {
    printf 'error: RT_TIMEOUT_SEC=%s is shorter than the complete phase budget %s\n' "$timeout_sec" "$minimum_outer_timeout" >&2
    exit 2
}
[[ "$progress_timeout" =~ ^[0-9]+$ ]] && (( progress_timeout > 0 )) || {
    printf 'error: RT_PROGRESS_TIMEOUT_SEC must be a positive integer\n' >&2
    exit 2
}

work="${repo_root}/tmp/rt-partition"
out_root="${RT_OUTPUT_ROOT:-${repo_root}/results/task1/matrix}"
out_dir="${out_root}/${scenario}"
board_toml="${repo_root}/scripts/test/rt-partition/board-qemu-aarch64-rt.toml"
linux_template="${repo_root}/scripts/test/rt-partition/vm-aarch64-rt-linux.toml"
zephyr_template="${repo_root}/scripts/test/rt-partition/rt-partition-zephyr.toml"
linux_config="${work}/generated-${scenario}-linux.toml"
zephyr_config="${work}/generated-${scenario}-zephyr.toml"
qemu_config="${work}/generated-${scenario}-qemu.toml"
serial_sock="${work}/serial-${scenario}.sock"
qmp_sock="${work}/qmp-${scenario}.sock"
steps="${work}/steps-${scenario}.txt"
run_log="${out_dir}/run.log"
build_log="${out_dir}/build-qemu.log"

for path in "$board_toml" "$linux_template" "$zephyr_template"; do
    [[ -f "$path" ]] || { printf 'error: missing %s\n' "$path" >&2; exit 1; }
done
for path in "$work/linux-qemu" "$work/rt-linux-initramfs.cpio.gz" \
    "$work/zephyr-periodic.bin" "$work/zephyr-periodic.manifest"; do
    [[ -f "$path" ]] || {
        printf 'error: missing %s (stage the guest images and run build-rt-tools.sh)\n' "$path" >&2
        exit 1
    }
done

rg -a -F "PERIODIC LATENCY COMPLETE samples=%d" "$work/zephyr-periodic.bin" >/dev/null || {
    printf 'error: Zephyr image is not the periodic latency sampler\n' >&2
    exit 1
}
if rg -a -F "TASK2_MAIN_START" "$work/zephyr-periodic.bin" >/dev/null; then
    printf 'error: Zephyr image is the Task2 networking guest, not the periodic sampler\n' >&2
    exit 1
fi
zephyr_entry="$(sed -n 's/^entry_point=//p' "$work/zephyr-periodic.manifest")"
zephyr_samples="$(sed -n 's/^sample_count=//p' "$work/zephyr-periodic.manifest")"
zephyr_start_gated="$(sed -n 's/^start_gated=//p' "$work/zephyr-periodic.manifest")"
[[ "$zephyr_entry" =~ ^0x[0-9a-fA-F]+$ ]] || {
    printf 'error: invalid Zephyr entry point in manifest: %s\n' "$zephyr_entry" >&2
    exit 1
}
[[ "$zephyr_samples" == "300" ]] || {
    printf 'error: Zephyr manifest sample count is not 300: %s\n' "$zephyr_samples" >&2
    exit 1
}
[[ "$zephyr_start_gated" == "1" ]] || {
    printf 'error: matrix Zephyr image must be built with ZEPHYR_START_GATED=1\n' >&2
    exit 1
}
rg -a -F "PERIODIC LATENCY READY" "$work/zephyr-periodic.bin" >/dev/null || {
    printf 'error: matrix Zephyr image does not contain the UART start gate\n' >&2
    exit 1
}

mkdir -p "$work" "$out_dir"
rm -f "$serial_sock" "$qmp_sock" "$run_log" "$build_log" \
    "$out_dir/cyclictest.csv" "$out_dir/linux-cpustat.csv" \
    "$out_dir/cyclictest-summary.txt" \
    "$out_dir/zephyr.csv" "$out_dir/zephyr-stats.txt" \
    "$out_dir/vmexit-before.txt" "$out_dir/vmexit-zephyr-after.txt" \
    "$out_dir/vmexit-after.txt" \
    "$out_dir/vmexit-stat.txt" "$out_dir/host-periodic-ticks.csv" \
    "$out_dir/meta.txt" "$out_dir/sha256sums" \
    "$out_dir/linux-qemu" "$out_dir/rt-linux-initramfs.cpio.gz" \
    "$out_dir/zephyr-periodic.bin" "$out_dir/zephyr-periodic.manifest" \
    "$out_dir/axvisor.bin" \
    "$out_dir/post-stall/query-status.json" \
    "$out_dir/post-stall/query-cpus-fast.json" \
    "$out_dir/post-stall/query-chardev.json" \
    "$out_dir/post-stall/info-registers-1.json" \
    "$out_dir/post-stall/info-registers-2.json" \
    "$out_dir/post-stall/qmp-error.txt" \
    "$out_dir/post-stall/serial-actions.txt" \
    "$out_dir/post-stall/serial-tail.bin"

cmdline="console=ttyAMA0 rdinit=/init devtmpfs.mount=1 loglevel=7 isolcpus=${rt_cpu} nohz_full=${rt_cpu} irqaffinity=${load_cpu} rt_scenario=${scenario} rt_cpu=${rt_cpu} rt_load_cpu=${load_cpu} rt_loops=${cyclictest_loops} rt_duration_sec=${duration_sec} rt_interval_us=${interval_us} rt_maxlat_us=${maxlat_us} rt_priority=${priority} rt_start_delay_sec=${start_delay_sec}"

python3 - "$linux_template" "$linux_config" "$cmdline" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
cmdline = sys.argv[3]
lines = source.read_text().splitlines()
replaced = False
for index, line in enumerate(lines):
    if line.startswith("cmdline = "):
        lines[index] = f'cmdline = "{cmdline}"'
        replaced = True
        break
if not replaced:
    raise SystemExit("Linux VM template has no cmdline field")
destination.write_text("\n".join(lines) + "\n")
PY

python3 - "$zephyr_template" "$zephyr_config" "$zephyr_guest_type" "$zephyr_entry" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
guest_type = sys.argv[3]
entry_point = sys.argv[4]
lines = source.read_text().splitlines()
found_guest_type = False
found_entry_point = False
for index, line in enumerate(lines):
    if line.startswith("guest_type = "):
        lines[index] = f'guest_type = "{guest_type}"'
        found_guest_type = True
    elif line.startswith("entry_point = "):
        lines[index] = f"entry_point = {entry_point}"
        found_entry_point = True
if not found_guest_type:
    raise SystemExit("Zephyr VM template has no guest_type field")
if not found_entry_point:
    raise SystemExit("Zephyr VM template has no entry_point field")
destination.write_text("\n".join(lines) + "\n")
PY

host_append_line=""
if [[ -n "$dedicated_cpus" ]]; then
    host_append_line="  \"-append\", \"dedicated_cpus=${dedicated_cpus}\","
fi
cat > "$qemu_config" <<EOF
args = [
  "-display", "none",
  "-monitor", "none",
  "-serial", "unix:${serial_sock},server,nowait",
  "-cpu", "cortex-a72",
  "-machine", "virt,virtualization=on,gic-version=3",
  "-smp", "4",
  "-m", "8g",
${host_append_line}
  "-qmp", "unix:${qmp_sock},server,nowait",
]
fail_regex = ["TASK2_ERROR=", "RT_CYCLICTEST_ERROR", "(?i)panic"]
success_regex = ["RT_CYCLICTEST_COMPLETE", "PERIODIC LATENCY COMPLETE"]
to_bin = true
uefi = false
EOF

cat > "$steps" <<EOF
expect 120 Default guest initialized
expect ${linux_start_timeout} RT_CYCLICTEST_START
expect 60 RT_PROGRESS uptime_s=
detach
expect 10 \[Axvisor\] detached VM\[1\] console
cmd vmexit stat
sleep 2
cmd vm console 2
expect 10 PERIODIC LATENCY READY
send-until 60 0.5 g PERIODIC LATENCY START
expect ${zephyr_timeout} PERIODIC LATENCY COMPLETE samples=300
detach
expect 10 \[Axvisor\] detached VM\[2\] console
cmd vmexit stat
sleep 2
cmd vm console 1
sleep 1
expect ${experiment_timeout} RT_CYCLICTEST_COMPLETE
expect ${result_drain_timeout} RT_INIT_DONE scenario=${scenario}
expect 30 \[Axvisor\] VM\[1\] stopped; returning to the management shell
cmd vmexit stat
sleep 2
qmp-quit ${qmp_sock}
EOF

start_ns="$(date +%s%N)"
printf 'rt_experiment scenario=%s mode=%s start_ns=%s expected_runtime_sec=%s\n' \
    "$scenario" "$run_mode" "$start_ns" "$expected_runtime_sec" | tee "$run_log"

cd "$repo_root"
timeout "$timeout_sec" cargo xtask axvisor qemu \
    --config "$board_toml" \
    --qemu-config "$qemu_config" \
    --vmconfigs "$linux_config" \
    --vmconfigs "$zephyr_config" \
    > "$build_log" 2>&1 &
run_pid=$!

cleanup() {
    if [[ -n "${run_pid:-}" ]] && kill -0 "$run_pid" 2>/dev/null; then
        kill -TERM "$run_pid" 2>/dev/null || true
        wait "$run_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

socket_wait_deadline=$((SECONDS + 600))
while [[ ! -S "$serial_sock" ]]; do
    if ! kill -0 "$run_pid" 2>/dev/null; then
        printf 'error: Axvisor build/run exited before the serial socket appeared\n' >&2
        tail -80 "$build_log" >&2
        exit 1
    fi
    (( SECONDS < socket_wait_deadline )) || {
        printf 'error: serial socket did not appear within 600 seconds\n' >&2
        tail -80 "$build_log" >&2
        exit 1
    }
    sleep 0.05
done

python3 "$repo_root/scripts/test/net-dual-guest/serial_console.py" \
    "$serial_sock" "$run_log" --script "$steps" --verbose \
    --timestamp-lines --progress-regex 'RT_PROGRESS uptime_s=' \
    --progress-timeout "$progress_timeout" --qmp-sock "$qmp_sock" \
    --forensics-dir "$out_dir/post-stall" 2>> "$build_log"

set +e
wait "$run_pid"
run_status=$?
set -e
run_pid=""
(( run_status == 0 )) || {
    printf 'error: cargo xtask/QEMU exited with status %s\n' "$run_status" >&2
    tail -80 "$build_log" >&2
    exit 1
}

end_ns="$(date +%s%N)"
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
printf 'rt_experiment end_ns=%s elapsed_ms=%s\n' "$end_ns" "$elapsed_ms" | tee -a "$run_log"

python3 - "$run_log" "$out_dir" <<'PY'
import csv
import re
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
out = Path(sys.argv[2])
raw_log = log_path.read_text(errors="replace")
progress = re.findall(
    r"^\[host_monotonic_s=([0-9.]+)\].*RT_PROGRESS uptime_s=([0-9.]+)",
    raw_log,
    flags=re.MULTILINE,
)
if len(progress) >= 2:
    host_elapsed = float(progress[-1][0]) - float(progress[0][0])
    guest_elapsed = float(progress[-1][1]) - float(progress[0][1])
    ratio = guest_elapsed / host_elapsed if host_elapsed > 0 else 0.0
    (out / "progress.txt").write_text(
        f"markers={len(progress)}\n"
        f"host_elapsed_s={host_elapsed:.6f}\n"
        f"guest_elapsed_s={guest_elapsed:.6f}\n"
        f"guest_wall_ratio={ratio:.9f}\n"
    )
else:
    (out / "progress.txt").write_text(f"markers={len(progress)}\n")
log = re.sub(r"(?m)^\[host_monotonic_s=[0-9.]+\] ", "", raw_log)

starts = [match.start() for match in re.finditer(r"VM-exit counters per physical CPU", log)]
if len(starts) < 3:
    raise SystemExit(f"expected at least three vmexit snapshots, found {len(starts)}")
blocks = []
for index, start in enumerate(starts):
    end = starts[index + 1] if index + 1 < len(starts) else len(log)
    block = log[start:end]
    block = re.split(r"\n(?:\[Axvisor\]|\[driver\]|rt_experiment)", block, maxsplit=1)[0]
    blocks.append(block.rstrip() + "\n")
(out / "vmexit-before.txt").write_text(blocks[0])
(out / "vmexit-zephyr-after.txt").write_text(blocks[1])
(out / "vmexit-after.txt").write_text(blocks[-1])
(out / "vmexit-stat.txt").write_text(
    "\n--- before ---\n"
    + blocks[0]
    + "\n--- zephyr-after ---\n"
    + blocks[1]
    + "\n--- linux-final ---\n"
    + blocks[-1]
)

header = "sequence,timestamp_ns,deadline_ns,actual_ns,jitter_ns"
header_index = log.rfind(header)
complete_index = log.rfind("PERIODIC LATENCY COMPLETE samples=300")
if header_index < 0 or complete_index < header_index:
    raise SystemExit("Zephyr periodic CSV block is missing")
rows = []
ansi_escape = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
for line in log[header_index + len(header):complete_index].splitlines():
    candidate = ansi_escape.sub("", line.strip())
    candidate = re.sub(r"^\[VM 2\] ", "", candidate)
    if re.fullmatch(r"\d+,-?\d+,-?\d+,-?\d+,-?\d+", candidate):
        rows.append(candidate.split(","))
if len(rows) != 300:
    raise SystemExit(f"expected 300 Zephyr samples, found {len(rows)}")
if [int(row[0]) for row in rows] != list(range(300)):
    raise SystemExit("Zephyr sample sequence is incomplete or out of order")
with (out / "zephyr.csv").open("w", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(header.split(","))
    writer.writerows(rows)

cpu_rows = []
pattern = re.compile(
    r"RT_CPUSTAT sample=(\d+) cpu=cpu(\d+) user=(\d+) nice=(\d+) "
    r"system=(\d+) idle=(\d+) iowait=(\d+) irq=(\d+) softirq=(\d+) steal=(\d+)"
)
for match in pattern.finditer(log):
    cpu_rows.append(match.groups())
if not cpu_rows:
    raise SystemExit("Linux per-CPU load samples are missing")
with (out / "linux-cpustat.csv").open("w", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(["sample", "cpu", "user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"])
    writer.writerows(cpu_rows)
PY

python3 "$repo_root/scripts/test/rt-partition/cyclictest-hist-to-csv.py" \
    "$run_log" "$out_dir/cyclictest.csv" "$out_dir/cyclictest-summary.txt"
python3 "$repo_root/scripts/test/rt-partition/host-periodic-ticks-to-csv.py" \
    "$run_log" "$out_dir/host-periodic-ticks.csv" "${host_tick_args[@]}"
python3 "$repo_root/scripts/test/rt_latency_stats.py" \
    "$out_dir/zephyr.csv" > "$out_dir/zephyr-stats.txt"

axvisor_bin="$(find "$repo_root/target" -path '*/release/axvisor.bin' -type f -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$axvisor_bin" && -f "$axvisor_bin" ]] || { printf 'error: built axvisor.bin not found\n' >&2; exit 1; }
strings "$axvisor_bin" | rg -F "$cmdline" >/dev/null || {
    printf 'error: generated guest cmdline is not embedded in axvisor.bin\n' >&2
    exit 1
}

python3 - "$run_log" "$out_dir/cyclictest.csv" "$out_dir/cyclictest-summary.txt" \
    "$scenario" "$run_mode" "$loops" "$duration_sec" "$elapsed_ms" <<'PY'
import csv
import re
import sys
from decimal import Decimal
from pathlib import Path

log_path, csv_path, summary_path = map(Path, sys.argv[1:4])
scenario = sys.argv[4]
run_mode = sys.argv[5]
loops = int(sys.argv[6])
duration_sec = int(sys.argv[7])
elapsed_ms = int(sys.argv[8])
log = re.sub(
    r"(?m)^\[host_monotonic_s=[0-9.]+\] ",
    "",
    log_path.read_text(errors="replace"),
)
required = [
    f"RT_INIT scenario={scenario}",
    "RT_CYCLICTEST_START",
    "PERIODIC LATENCY READY",
    "PERIODIC LATENCY START",
    "RT_CYCLICTEST_TIMING_START",
    "RT_CYCLICTEST_TIMING_END",
    "# Histogram",
    "RT_CYCLICTEST_COMPLETE",
    f"RT_INIT_DONE scenario={scenario}",
    "PERIODIC LATENCY COMPLETE samples=300",
]
missing = [marker for marker in required if marker not in log]
if missing:
    raise SystemExit("missing acceptance markers: " + ", ".join(missing))
if "RT_CYCLICTEST_ERROR" in log:
    raise SystemExit("cyclictest reported an execution error")
linux_start = log.index("RT_CYCLICTEST_START")
zephyr_start = log.index("PERIODIC LATENCY START")
zephyr_complete = log.index("PERIODIC LATENCY COMPLETE samples=300")
linux_complete = log.index("RT_CYCLICTEST_COMPLETE")
if not linux_start < zephyr_start < zephyr_complete < linux_complete:
    raise SystemExit("Zephyr samples were not captured inside the Linux workload window")
start_matches = re.findall(r"RT_CYCLICTEST_TIMING_START uptime_s=([0-9]+(?:\.[0-9]+)?)", log)
end_matches = re.findall(r"RT_CYCLICTEST_TIMING_END uptime_s=([0-9]+(?:\.[0-9]+)?)", log)
if len(start_matches) != 1 or len(end_matches) != 1:
    raise SystemExit("expected exactly one cyclictest guest-uptime interval")
start_uptime_s = Decimal(start_matches[0])
end_uptime_s = Decimal(end_matches[0])
guest_elapsed_s = end_uptime_s - start_uptime_s
if guest_elapsed_s <= 0:
    raise SystemExit("cyclictest guest-uptime interval is not positive")
with csv_path.open(newline="") as stream:
    bucket_samples = sum(int(row["count"]) for row in csv.DictReader(stream))
summary = {}
for line in summary_path.read_text().splitlines():
    name, value = line.split("=", 1)
    summary[name] = int(value)
if summary["bucket_samples"] != bucket_samples:
    raise SystemExit("cyclictest summary does not match histogram buckets")
if summary["total_samples"] != bucket_samples + summary["overflow_samples"]:
    raise SystemExit("cyclictest total does not include all histogram overflows")
if run_mode == "loops" and summary["total_samples"] != loops:
    raise SystemExit(
        f"cyclictest sample count mismatch: {summary['total_samples']} != requested {loops}"
    )
if run_mode == "duration" and duration_sec <= 0:
    raise SystemExit("duration mode requires a positive duration")
if summary["total_samples"] <= 0:
    raise SystemExit("cyclictest histogram has no samples")
if run_mode == "duration":
    minimum_guest_elapsed_s = Decimal(duration_sec) * Decimal("0.9")
    if guest_elapsed_s < minimum_guest_elapsed_s:
        raise SystemExit(
            "cyclictest covered too little guest time: "
            f"{guest_elapsed_s} s < {minimum_guest_elapsed_s} s"
        )
print(
    f"accepted scenario={scenario} mode={run_mode} requested_loops={loops} "
    f"duration_sec={duration_sec} total_samples={summary['total_samples']} "
    f"bucket_samples={bucket_samples} overflow_samples={summary['overflow_samples']} "
    f"guest_elapsed_s={guest_elapsed_s} elapsed_ms={elapsed_ms}"
)
PY

{
    printf 'scenario=%s\n' "$scenario"
    printf 'git_commit=%s\n' "$(git rev-parse HEAD)"
    printf 'run_mode=%s\n' "$run_mode"
    printf 'requested_loops=%s\n' "$loops"
    printf 'duration_sec=%s\n' "$duration_sec"
    printf 'cyclictest_loops=%s\n' "$cyclictest_loops"
    printf 'interval_us=%s\n' "$interval_us"
    printf 'expected_runtime_sec=%s\n' "$expected_runtime_sec"
    printf 'tcg_runtime_scale=%s\n' "$runtime_scale"
    printf 'runtime_scale_source=%s\n' "$runtime_scale_source"
    printf 'expected_wall_runtime_sec=%s\n' "$expected_wall_runtime_sec"
    printf 'elapsed_ms=%s\n' "$elapsed_ms"
    printf 'dedicated_cpus=%s\n' "${dedicated_cpus:-none}"
    printf 'zephyr_guest_type=%s\n' "$zephyr_guest_type"
    printf 'progress_timeout_sec=%s\n' "$progress_timeout"
    printf 'result_drain_timeout_sec=%s\n' "$result_drain_timeout"
    printf 'timestamp_format=host_monotonic_s=seconds\n'
    printf 'realtime_trace=disabled\n'
    printf 'host_periodic_tick_policy=%s\n' "${host_tick_args[*]:-record-only}"
    printf 'linux_rt_cpu=%s\n' "$rt_cpu"
    printf 'linux_load_cpu=%s\n' "$load_cpu"
    printf 'guest_cmdline=%s\n' "$cmdline"
    printf 'axvisor_bin=%s\n' "$axvisor_bin"
    printf 'build_command=cargo xtask axvisor qemu --config %s --qemu-config %s --vmconfigs %s --vmconfigs %s\n' \
        "$board_toml" "$qemu_config" "$linux_config" "$zephyr_config"
} > "$out_dir/meta.txt"

cp "$linux_config" "$out_dir/linux.toml"
cp "$zephyr_config" "$out_dir/zephyr.toml"
cp "$qemu_config" "$out_dir/qemu.toml"
cp "$work/linux-qemu" "$out_dir/"
cp "$work/rt-linux-initramfs.cpio.gz" "$out_dir/"
cp "$work/zephyr-periodic.bin" "$out_dir/"
cp "$work/zephyr-periodic.manifest" "$out_dir/"
cp "$axvisor_bin" "$out_dir/"
(
    cd "$out_dir"
    sha256sum \
        build-qemu.log run.log cyclictest.csv cyclictest-summary.txt \
        linux-cpustat.csv zephyr.csv zephyr-stats.txt progress.txt \
        vmexit-before.txt vmexit-zephyr-after.txt vmexit-after.txt vmexit-stat.txt \
        host-periodic-ticks.csv \
        linux.toml zephyr.toml qemu.toml meta.txt \
        linux-qemu rt-linux-initramfs.cpio.gz zephyr-periodic.bin \
        zephyr-periodic.manifest axvisor.bin > sha256sums
)

printf 'accepted: %s\n' "$out_dir"
