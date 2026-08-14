#!/usr/bin/env bash
set -euo pipefail

# One-command RT-partition measurement: boot the dual-guest topology, run the
# cyclictest scenario inside the Linux guest, capture the console, and produce
# evidence under results/task1/cyclictest/<scenario>/.
#
# Scenarios (T2.2 matrix):
#   idle          Linux idle
#   stress-noiso  Linux stress-ng --cpu 2 --vm 1 --vm-bytes 64M, no isolation
#   stress-rt     same load with RT partition + preemption
#
# Environment overrides:
#   RT_SCENARIO   idle|stress-noiso|stress-rt   (default: idle)
#   RT_LOOPS      cyclictest loops              (default: 1800000, 30 min)
#   RT_INTERVAL_US, RT_MAXLAT_US, RT_PRIORITY, RT_CPU
#   RT_QEMU       qemu binary                   (default: qemu-system-aarch64)
#
# Outputs:
#   results/task1/cyclictest/<scenario>/{run.log,cyclictest.csv,top.csv,
#   vmexit-stat.txt,meta.txt}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scenario="${RT_SCENARIO:-idle}"
qemu="${RT_QEMU:-qemu-system-aarch64}"
loops="${RT_LOOPS:-1800000}"
interval_us="${RT_INTERVAL_US:-1000}"
maxlat_us="${RT_MAXLAT_US:-400}"
priority="${RT_PRIORITY:-90}"
rt_cpu="${RT_CPU:-0}"
timeout_sec="${RT_TIMEOUT_SEC:-2200}"

work="${repo_root}/tmp/rt-partition"
out_dir="${repo_root}/results/task1/cyclictest/$scenario"
qemu_toml="${repo_root}/scripts/test/rt-partition/qemu-aarch64-rt.toml"
vm_linux="${repo_root}/scripts/test/rt-partition/vm-aarch64-rt-linux.toml"
vm_zephyr="${repo_root}/scripts/test/rt-partition/vm-aarch64-rt-zephyr.toml"
serial_sock="$work/serial-rt.sock"
qmp_sock="$work/qmp-rt.sock"
vmexit_log="$out_dir/vmexit-stat.txt"
top_log="$out_dir/top.csv"
run_log="$out_dir/run.log"

for path in "$qemu_toml" "$vm_linux" "$vm_zephyr"; do
    [[ -f "$path" ]] || { printf 'error: missing %s\n' "$path" >&2; exit 1; }
done
for path in "$work/linux-qemu" "$work/rt-linux-initramfs.cpio.gz" "$work/zephyr-rt.bin"; do
    [[ -f "$path" ]] || { printf 'error: missing %s (run build-rt-tools.sh and stage guest images)\n' "$path" >&2; exit 1; }
done

mkdir -p "$out_dir"
rm -f "$serial_sock" "$qmp_sock"
: > "$run_log"

start_ns=$(date +%s%N)
printf 'rt_experiment scenario=%s start_ns=%s\n' "$scenario" "$start_ns" | tee -a "$run_log"

# Boot the hypervisor with the measurement cmdline injected.
cmdline="root=/dev/nvme0n1 rw init=/init isolcpus=1 nohz_full=1 irqaffinity=0 rt_scenario=$scenario rt_cpu=$rt_cpu rt_loops=$loops rt_interval_us=$interval_us rt_maxlat_us=$maxlat_us rt_priority=$priority"

"$qemu" \
    -display none -monitor none \
    -serial "unix:$serial_sock,server,nowait" \
    -cpu cortex-a72 \
    -machine "virt,virtualization=on,gic-version=3" \
    -smp 4 -m 8g \
    -kernel "$repo_root/target/aarch64-unknown-linux-musl/debug/axvisor" \
    -qmp "unix:$qmp_sock,server,nowait" \
    >"$out_dir/qemu-stdout.log" 2>&1 &

qemu_pid=$!
cleanup() {
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT

steps="$work/rt-cyclictest.steps"
cat > "$steps" <<EOF
sleep 30
expect 120 RT_CYCLICTEST_COMPLETE
expect 60 RT_INIT_DONE
cmd vmexit stat
sleep 2
EOF

python3 "$repo_root/scripts/test/net-dual-guest/serial_console.py" \
    "$serial_sock" "$run_log" --script "$steps" || true

end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
printf 'rt_experiment end_ns=%s elapsed_ms=%s\n' "$end_ns" "$elapsed_ms" | tee -a "$run_log"

# Extract the vmexit stat table (last occurrence) for the record.
python3 - "$run_log" "$vmexit_log" <<'PYEOF'
import re
import sys

log = open(sys.argv[1]).read()
blocks = re.findall(r"VM-exit counters per physical CPU.*?(?=\n\n|\Z)", log, re.S)
if not blocks:
    print("vmexit stat table not found in log")
    sys.exit(0)
open(sys.argv[2], "w").write(blocks[-1].rstrip() + "\n")
print(f"vmexit stat table saved ({len(blocks[-1])} bytes)")
PYEOF

# Convert the cyclictest histogram to CSV.
python3 "$repo_root/scripts/test/rt-partition/cyclictest-hist-to-csv.py" \
    "$run_log" "$out_dir/cyclictest.csv" || true

# Extract the top samples (load distribution) as CSV.
python3 - "$run_log" "$top_log" <<'PYEOF'
import re
import sys

log = open(sys.argv[1]).read()
rows = []
for m in re.finditer(r"RT_CYCLICTEST_START(.*?)RT_CYCLICTEST_COMPLETE", log, re.S):
    body = m.group(1)
    for line in body.splitlines():
        parts = line.split()
        if len(parts) >= 9 and parts[0].isdigit() and "%" in parts[-3]:
            rows.append((parts[0], parts[-2], parts[-3]))
with open(sys.argv[2], "w") as f:
    f.write("pid,cpu%,mem%\n")
    for pid, cpu, mem in rows:
        f.write(f"{pid},{cpu},{mem}\n")
print(f"top samples={len(rows)}")
PYEOF

{
    printf 'scenario=%s\n' "$scenario"
    printf 'command: %s -smp 4 -kernel axvisor(debug) -vmconfigs %s %s\n' "$qemu" "$vm_linux" "$vm_zephyr"
    printf 'cmdline: %s\n' "$cmdline"
    printf 'elapsed_ms=%s\n' "$elapsed_ms"
    printf 'qemu_pid=%s\n' "$qemu_pid"
    printf 'host_cpu_load: see top.csv\n'
    printf 'sha256(initramfs)=%s\n' "$(cat "$work/rt-linux-initramfs.cpio.gz.sha256" 2>/dev/null || echo unknown)"
} > "$out_dir/meta.txt"

sha256sum "$out_dir"/* > "$out_dir/sha256sums"
printf 'done: %s\n' "$out_dir"
