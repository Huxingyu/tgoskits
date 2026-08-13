#!/usr/bin/env bash
set -euo pipefail

# Task-3 runtime fault-injection experiment on the in-hypervisor
# virtio-net switch. The console driver owns the whole lifecycle: loop
# start, capture on, a timed hypervisor-side blackout (`virtnet drop on/off`)
# that drops every frame in both directions, Safe entry, recovery, pcap
# streaming, and the QMP quit.
#
# The blackout window is anchored to the controller's own elapsed_ms log
# (25s..~35s of loop time, matching the P3-proxy window): both T2N1
# endpoints exhaust retransmission/heartbeat and enter Safe, then
# resynchronize when the gate is lifted.
#
# Usage: run-task3-switch-fault.sh <label>

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
label="${1:?label required}"
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

cp "$workdir/linux-task2/task2-linux-initramfs-ai.cpio.gz" \
    "$workdir/linux-task2/task2-linux-initramfs.cpio.gz"
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
# Wait until the loop reaches ~25s of elapsed time (25000..29999 ms).
expect 120 elapsed_ms=2[5-9][0-9]{3}
# Engage the blackout; guests keep running, every frame is dropped.
detach
cmd virtnet drop on
expect 20 virtnet: blackout ON
attach 1
# Both endpoints exhaust retransmission and enter Safe.
expect 90 TASK2_SAFE
# Keep the link down for a ~10s blackout window.
hold 10
# Lift the blackout and wait for the T2N1 resynchronization.
detach
cmd virtnet drop off
expect 20 virtnet: blackout OFF
attach 1
expect 90 TASK2_RECOVERED
# Observe resumed closed-loop cycles (>=45s of loop time).
expect 120 elapsed_ms=(4[5-9]|[5-9][0-9]|[1-9][0-9][0-9])[0-9]{3}
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
    "$serial_sock" "$log" --script "$steps"
driver_status=$?

sleep 5
pkill -f "tg-xtask axvisor qemu" 2>/dev/null || true
pkill -f "qemu-system-[a]arch64" 2>/dev/null || true
sleep 2

if [ "$driver_status" -ne 0 ]; then
    echo "console driver failed with status $driver_status; tail of run log:"
    tail -30 "$log"
    exit "$driver_status"
fi

echo "run $label (fault) finished; log=$log build_log=$build_log"
ls -la "$workdir"/switch.vm*.pcap 2>/dev/null || true

# Archive the evidence under results/task3/switch/fault-<label>/.
out_dir="$repo_root/results/task3/switch/fault-$label"
mkdir -p "$out_dir"
cp "$log" "$out_dir/run.log" 2>/dev/null || true
cp "$build_log" "$out_dir/build.log" 2>/dev/null || true
cp "$workdir/switch.vm1.pcap" "$out_dir/linux.pcap" 2>/dev/null || true
cp "$workdir/switch.vm2.pcap" "$out_dir/rtos.pcap" 2>/dev/null || true
printf 'label = "%s"\nmode = "fault"\n' "$label" > "$out_dir/manifest.toml"
echo "archived evidence under $out_dir"
