#!/usr/bin/env bash
set -euo pipefail

# Run one Task-3 dual-Guest closed-loop experiment on the in-hypervisor
# virtio-net switch. The console driver owns the whole lifecycle: it waits
# for the loop, enables frame capture, runs until the controller reaches
# MIN_ELAPSED_MS, streams the captured frames out as pcap, and quits QEMU
# over QMP.
#
# Usage: run-task3-switch.sh <label> <ai|baseline>
# Env:    MIN_ELAPSED_MS (default 35000)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
label="${1:?label required}"
mode="${2:?mode required: ai or baseline}"
min_elapsed_ms="${MIN_ELAPSED_MS:-35000}"
workdir="$repo_root/tmp/net-dual-guest"
log="/tmp/task3-${label}.log"
build_log="/tmp/task3-${label}-build.log"
qemu_sock="$workdir/qmp-switch.sock"
serial_sock="$workdir/serial-switch.sock"
steps="/tmp/task3-${label}.steps"
run_pid=""

cleanup() {
    pkill -f "tg-xtask axvisor qemu" 2>/dev/null || true
    pkill -f "qemu-system-[a]arch64" 2>/dev/null || true
}
trap cleanup EXIT

case "$mode" in
    ai)       initramfs="$workdir/linux-task2/task2-linux-initramfs-ai.cpio.gz" ;;
    baseline) initramfs="$workdir/linux-task2/task2-linux-initramfs-baseline.cpio.gz" ;;
    *) echo "mode must be ai or baseline" >&2; exit 1 ;;
esac

cp "$initramfs" "$workdir/linux-task2/task2-linux-initramfs.cpio.gz"
rm -f "$qemu_sock" "$serial_sock" "$log" \
    "$workdir/switch.vm1.pcap" "$workdir/switch.vm2.pcap"

cat > "$steps" <<EOF
# Wait for the control loop inside the boot-time console multiplex.
expect 420 TASK3_CONTROL_SENT
# Start frame capture, then watch the Linux controller console.
detach
cmd virtnet capture on
expect 20 virtnet: capture ON
attach 1
# Hold until the controller reports MIN_ELAPSED_MS of loop time
# (elapsed_ms=35000..39999 or 40000+).
expect 120 elapsed_ms=(3[5-9]|[4-9][0-9])[0-9]{3}
detach
dump-pcap $workdir/switch
qmp-quit $qemu_sock
EOF

rm -f "$log"
nohup cargo xtask axvisor qemu \
    --config scripts/test/net-dual-guest/axvisor-qemu-debug.toml \
    --qemu-config scripts/test/net-dual-guest/qemu-aarch64-p2-switch.toml \
    --vmconfigs scripts/test/net-dual-guest/vm-aarch64-p2-switch-linux.toml \
    --vmconfigs scripts/test/net-dual-guest/vm-aarch64-p2-switch-rtos.toml \
    --rootfs "$repo_root/tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img" \
    > "$build_log" 2>&1 &
run_pid=$!

for _ in $(seq 1 180); do
    if [ -S "$serial_sock" ]; then
        break
    fi
    if ! kill -0 "$run_pid" 2>/dev/null; then
        echo "axvisor run exited early; tail of build log:"
        tail -20 "$build_log"
        exit 1
    fi
    sleep 2
done
if [ ! -S "$serial_sock" ]; then
    echo "serial socket never appeared; tail of build log:"
    tail -20 "$build_log"
    exit 1
fi

python3 scripts/test/net-dual-guest/serial_console.py \
    "$serial_sock" "$log" --script "$steps" --verbose \
    2>> "$build_log"
driver_status=$?

sleep 5
pkill -f "tg-xtask axvisor qemu" 2>/dev/null || true
pkill -f "qemu-system-[a]arch64" 2>/dev/null || true
sleep 2

if [ "$driver_status" -ne 0 ]; then
    echo "console driver failed with status $driver_status; tail of run log:"
    tail -20 "$log"
    exit "$driver_status"
fi

echo "run $label ($mode) finished; log=$log build_log=$build_log"
ls -la "$workdir"/switch.vm*.pcap 2>/dev/null || true

# Archive the evidence under results/task3/switch/<label>/ so the next run's
# cleanup cannot overwrite it.
out_dir="$repo_root/results/task3/switch/$label"
mkdir -p "$out_dir"
cp "$log" "$out_dir/run.log" 2>/dev/null || true
cp "$build_log" "$out_dir/build.log" 2>/dev/null || true
cp "$workdir/switch.vm1.pcap" "$out_dir/linux.pcap" 2>/dev/null || true
cp "$workdir/switch.vm2.pcap" "$out_dir/rtos.pcap" 2>/dev/null || true
printf 'label = "%s"\nmode = "%s"\n' "$label" "$mode" > "$out_dir/manifest.toml"
echo "archived evidence under $out_dir"
