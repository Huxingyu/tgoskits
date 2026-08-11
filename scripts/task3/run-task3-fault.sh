#!/usr/bin/env bash
set -euo pipefail

# Task-3 M5 fault-injection experiment: run the AI controller, drop the RTOS
# data link through QMP, observe safe-state entry on both sides, restore the
# link and observe recovery, then quit QEMU.
#
# Usage: run-task3-fault.sh <label>

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
label="${1:?label required}"
workdir="$repo_root/tmp/net-dual-guest"
log="/tmp/task3-${label}.log"
qemu_sock="$workdir/qmp.sock"
qmp="$repo_root/scripts/test/net-dual-guest/qmp_link.py"

pkill -f "tg-xtask axvisor qemu" 2>/dev/null || true
pkill -f qemu-system-aarch64 2>/dev/null || true
sleep 3

cp "$workdir/linux-task2/task2-linux-initramfs-ai.cpio.gz" \
    "$workdir/linux-task2/task2-linux-initramfs.cpio.gz"
rm -f "$qemu_sock" "$workdir/linux.pcap" "$workdir/rtos.pcap"

nohup cargo xtask axvisor qemu \
    --config /tmp/task2-axvisor-qemu-debug.toml \
    --qemu-config scripts/test/net-dual-guest/qemu-aarch64-p2.toml \
    --vmconfigs scripts/test/net-dual-guest/vm-aarch64-p2-linux.toml \
    --vmconfigs scripts/test/net-dual-guest/vm-aarch64-p2-rtos.toml \
    --rootfs "$repo_root/tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img" \
    > "$log" 2>&1 &
run_pid=$!

wait_for() {
    local pattern="$1"
    local timeout="${2:-300}"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if grep -qE "$pattern" "$log"; then return 0; fi
        if ! kill -0 "$run_pid" 2>/dev/null; then
            echo "run process exited early:"; tail -5 "$log"; exit 1
        fi
        sleep 5
    done
    echo "timeout waiting for $pattern"; exit 1
}

echo "[fault] dropping net-linux before the guests boot"
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ -S "$qemu_sock" ] && python3 "$qmp" "$qemu_sock" net-linux off 2>/dev/null; then
        echo "[fault] link down confirmed pre-boot"
        break
    fi
    sleep 2
done
python3 "$qmp" "$qemu_sock" net-linux off

echo "[fault] waiting for the controller app to enter Safe"
wait_for "TASK2_SAFE" 300

echo "[fault] link up (net-linux on)"
python3 "$qmp" "$qemu_sock" net-linux on

echo "[fault] waiting for recovery and a resumed control loop"
wait_for "TASK2_RECOVERED" 60
wait_for "TASK3_CONTROL_SENT elapsed_ms=" 60
sleep 10

echo "[fault] quitting"
python3 "$qmp" "$qemu_sock" quit || true
sleep 15
pkill -f "tg-xtask axvisor qemu" 2>/dev/null || true
sleep 3
echo "run $label (fault) finished; log=$log"
