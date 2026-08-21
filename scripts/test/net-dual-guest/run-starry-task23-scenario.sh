#!/usr/bin/env bash
set -euo pipefail

# Run one real StarryOS + Zephyr Task-2/Task-3 scenario and retain both
# Guest pcaps, console evidence, exact commands, manifests, and hashes.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scenario="${1:?usage: run-starry-task23-scenario.sh SCENARIO OUTPUT_DIR}"
output_dir="${2:?usage: run-starry-task23-scenario.sh SCENARIO OUTPUT_DIR}"
runtime_dir="$repo_root/tmp/net-dual-guest"
qemu_sock="$runtime_dir/qmp-starry-zephyr-msix1-capture.sock"
serial_sock="$runtime_dir/serial-starry-zephyr-msix1-capture.sock"
capture_prefix="$runtime_dir/starry-task23-current"
steps="$output_dir/steps.txt"
run_log="$output_dir/run.log"
build_log="$output_dir/build.log"
run_pid=""

case "$scenario" in
    normal|blackout|model-rejected)
        zephyr_variant="normal"
        ;;
    drop-ack)
        zephyr_variant="drop-ack"
        ;;
    out-of-order|invalid-parameter)
        zephyr_variant="normal"
        ;;
    *)
        printf 'error: unknown scenario %s\n' "$scenario" >&2
        exit 2
        ;;
esac

case "$scenario" in
    normal|drop-ack|blackout) run_mode="normal" ;;
    *) run_mode="$scenario" ;;
esac

if [[ -d "$output_dir" ]] && find "$output_dir" -mindepth 1 -print -quit | grep -q .; then
    printf 'error: output directory is not empty: %s\n' "$output_dir" >&2
    exit 1
fi
mkdir -p "$output_dir"

if [[ "${ALLOW_DIRTY:-0}" != 1 ]] &&
    [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]]; then
    printf 'error: tracked worktree changes exist; commit them or set ALLOW_DIRTY=1 for a diagnostic run\n' >&2
    exit 1
fi

normal_dir="$runtime_dir/zephyr-task2-starry-normal"
drop_dir="$runtime_dir/zephyr-task2-starry-drop-ack"
if [[ "$zephyr_variant" == normal ]]; then
    selected_zephyr_dir="$normal_dir"
    expected_fault_mode="none"
else
    selected_zephyr_dir="$drop_dir"
    expected_fault_mode="drop-ack-once"
fi
for artifact in "$selected_zephyr_dir/zephyr-task2.bin" "$selected_zephyr_dir/manifest.toml"; do
    if [[ ! -s "$artifact" ]]; then
        printf 'error: missing Zephyr artifact: %s\n' "$artifact" >&2
        exit 1
    fi
done
if ! grep -q "^fault_mode = \"$expected_fault_mode\"$" "$selected_zephyr_dir/manifest.toml"; then
    printf 'error: Zephyr manifest fault mode does not match %s\n' "$scenario" >&2
    exit 1
fi

rootfs="$repo_root/tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img"
endpoint="$repo_root/target/starryos-task2-rust/aarch64-unknown-linux-musl/release/starryos-task2-endpoint"
endpoint_script="$repo_root/apps/starry/starryos-task2/t2n1-run.sh"
starry_image="$repo_root/target/aarch64-unknown-none-softfloat/release/starryos.bin"
axvisor_image="$repo_root/target/aarch64-unknown-linux-musl/release/axvisor.bin"
for artifact in "$rootfs" "$endpoint" "$endpoint_script" "$starry_image"; do
    if [[ ! -s "$artifact" ]]; then
        printf 'error: missing StarryOS artifact: %s\n' "$artifact" >&2
        exit 1
    fi
done

host_endpoint_sha256="$(sha256sum "$endpoint" | awk '{print $1}')"
rootfs_endpoint_sha256="$(
    debugfs -R 'dump /usr/bin/starry-t2n1-endpoint /dev/stdout' "$rootfs" 2>/dev/null |
        sha256sum | awk '{print $1}'
)"
host_script_sha256="$(sha256sum "$endpoint_script" | awk '{print $1}')"
rootfs_script_sha256="$(
    debugfs -R 'dump /usr/bin/t2n1-run.sh /dev/stdout' "$rootfs" 2>/dev/null |
        sha256sum | awk '{print $1}'
)"
if [[ "$host_endpoint_sha256" != "$rootfs_endpoint_sha256" ]]; then
    printf 'error: rootfs endpoint does not match current release binary\n' >&2
    exit 1
fi
if [[ "$host_script_sha256" != "$rootfs_script_sha256" ]]; then
    printf 'error: rootfs runner does not match current source script\n' >&2
    exit 1
fi
{
    printf 'host_endpoint_sha256=%s\n' "$host_endpoint_sha256"
    printf 'rootfs_endpoint_sha256=%s\n' "$rootfs_endpoint_sha256"
    printf 'host_script_sha256=%s\n' "$host_script_sha256"
    printf 'rootfs_script_sha256=%s\n' "$rootfs_script_sha256"
} > "$output_dir/rootfs-content-hashes.txt"

stop_owned_run() {
    if [[ -S "$qemu_sock" ]]; then
        python3 "$repo_root/scripts/test/net-dual-guest/qmp_link.py" "$qemu_sock" quit \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "$run_pid" ]] && kill -0 "$run_pid" 2>/dev/null; then
        kill -TERM "$run_pid" 2>/dev/null || true
        wait "$run_pid" 2>/dev/null || true
    fi
    for socket_path in "$qemu_sock" "$serial_sock"; do
        while read -r owner_pid; do
            [[ -n "$owner_pid" ]] && kill -TERM "$owner_pid" 2>/dev/null || true
        done < <(lsof -t -- "$socket_path" 2>/dev/null || true)
    done
}
trap stop_owned_run EXIT

for socket_path in "$qemu_sock" "$serial_sock"; do
    if lsof -t -- "$socket_path" >/dev/null 2>&1; then
        printf 'error: runtime socket is owned by another process: %s\n' "$socket_path" >&2
        exit 1
    fi
    rm -f -- "$socket_path"
done
rm -f -- "$capture_prefix.vm1.pcap" "$capture_prefix.vm2.pcap"

mkdir -p "$runtime_dir/zephyr-task2"
cp "$selected_zephyr_dir/zephyr-task2.bin" "$runtime_dir/zephyr-task2/zephyr-task2.bin"
cp "$selected_zephyr_dir/manifest.toml" "$runtime_dir/zephyr-task2/manifest.toml"

{
    printf 'detach\n'
    printf 'cmd virtnet capture on\n'
    printf 'expect 20 virtnet: capture ON\n'
    printf 'attach 1\n'
    printf 'expect 120 root@starry:/root #\n'
    printf 'cmd (sleep 2; sh /usr/bin/t2n1-run.sh %s) &\n' "$run_mode"
    case "$scenario" in
        normal)
            printf 'attach 2\n'
            printf 'expect 30 TASK2_CONTROL_RECEIVED seq=1 request=1\n'
            printf 'attach 1\n'
            printf 'expect 30 STARRY_T2N1_PASS\n'
            printf 'expect 30 STARRY_T2N1_STATUS_DELIVERED.*request=3\n'
            ;;
        drop-ack)
            printf 'attach 2\n'
            printf 'expect 30 TASK2_FAULT_DROP_ACK seq=1\n'
            printf 'attach 1\n'
            printf 'expect 30 STARRY_T2N1_RETRANSMIT seq=1 attempt=1\n'
            printf 'expect 30 STARRY_T2N1_ACK seq=1\n'
            printf 'expect 30 STARRY_T2N1_PASS\n'
            printf 'attach 2\n'
            printf 'expect 30 TASK2_FAULT_DROP_ACK_RECOVERED duplicate_seq=1\n'
            ;;
        out-of-order)
            printf 'attach 2\n'
            printf 'expect 30 TASK2_PROTOCOL_ERROR out_of_order=2 expected=1\n'
            printf 'attach 1\n'
            printf 'expect 30 STARRY_T2N1_FAULT_RECOVERY_COMPLETE mode=out-of-order\n'
            printf 'expect 30 STARRY_T2N1_PASS\n'
            ;;
        invalid-parameter)
            printf 'attach 2\n'
            printf 'expect 30 TASK2_PROTOCOL_ERROR invalid_parameter seq=1\n'
            printf 'attach 1\n'
            printf 'expect 30 STARRY_T2N1_FAULT_RECOVERY_COMPLETE mode=invalid-parameter\n'
            printf 'expect 30 STARRY_T2N1_PASS\n'
            ;;
        blackout)
            printf 'attach 1\n'
            printf 'expect 30 STARRY_T2N1_PASS\n'
            printf 'detach\n'
            printf 'cmd virtnet drop on\n'
            printf 'expect 20 virtnet: blackout ON\n'
            printf 'attach 1\n'
            printf 'expect 30 STARRY_T2N1_SAFE source=protocol\n'
            printf 'attach 2\n'
            printf 'expect 30 TASK2_SAFE state=Safe event=HeartbeatTimeout\n'
            printf 'detach\n'
            printf 'cmd virtnet drop off\n'
            printf 'expect 20 virtnet: blackout OFF\n'
            printf 'attach 1\n'
            printf 'expect 30 STARRY_T2N1_RECOVERED state=Active\n'
            printf 'expect 30 STARRY_T2N1_FAULT_RECOVERY_COMPLETE mode=normal\n'
            printf 'attach 2\n'
            printf 'expect 30 TASK2_CONTROL_RECEIVED.*request=\n'
            ;;
        model-rejected)
            printf 'attach 1\n'
            printf 'expect 30 TASK3_MODEL_REJECTED.*reason=NonFiniteOutput\n'
            printf 'expect 30 STARRY_T2N1_SAFE source=model reason=NonFiniteOutput\n'
            printf 'hold 3\n'
            ;;
    esac
    printf 'detach\n'
    printf 'dump-pcap %s\n' "$capture_prefix"
    printf 'qmp-quit %s\n' "$qemu_sock"
} > "$steps"

{
    printf 'scenario=%s\n' "$scenario"
    printf 'git_head=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
    printf 'zephyr_variant=%s\n' "$zephyr_variant"
    printf 'command=cargo xtask axvisor qemu --config scripts/test/net-dual-guest/axvisor-qemu-debug.toml --qemu-config scripts/test/net-dual-guest/qemu-aarch64-starry-zephyr-switch-msix1-capture.toml --vmconfigs scripts/test/net-dual-guest/vm-aarch64-starry-switch.toml --vmconfigs scripts/test/net-dual-guest/vm-aarch64-p2-switch-rtos.toml --rootfs tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img\n'
} > "$output_dir/command.txt"

(
    cd "$repo_root"
    cargo xtask axvisor qemu \
        --config scripts/test/net-dual-guest/axvisor-qemu-debug.toml \
        --qemu-config scripts/test/net-dual-guest/qemu-aarch64-starry-zephyr-switch-msix1-capture.toml \
        --vmconfigs scripts/test/net-dual-guest/vm-aarch64-starry-switch.toml \
        --vmconfigs scripts/test/net-dual-guest/vm-aarch64-p2-switch-rtos.toml \
        --rootfs tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img
) > "$build_log" 2>&1 &
run_pid=$!

for _ in $(seq 1 120); do
    [[ -S "$serial_sock" ]] && break
    if ! kill -0 "$run_pid" 2>/dev/null; then
        printf 'error: AxVisor exited before serial socket creation\n' >&2
        tail -40 "$build_log" >&2
        exit 1
    fi
    sleep 1
done
if [[ ! -S "$serial_sock" ]]; then
    printf 'error: serial socket did not appear\n' >&2
    tail -40 "$build_log" >&2
    exit 1
fi

(
    cd "$repo_root"
    python3 scripts/test/net-dual-guest/serial_console.py \
        "$serial_sock" "$run_log" --script "$steps" --verbose \
        --qmp-sock "$qemu_sock" --forensics-dir "$output_dir/forensics"
) 2>> "$build_log"

sleep 2
if kill -0 "$run_pid" 2>/dev/null; then
    wait "$run_pid" 2>/dev/null || true
fi
run_pid=""

for pcap in "$capture_prefix.vm1.pcap" "$capture_prefix.vm2.pcap"; do
    if [[ ! -s "$pcap" ]]; then
        printf 'error: missing pcap: %s\n' "$pcap" >&2
        exit 1
    fi
done
cp "$capture_prefix.vm1.pcap" "$output_dir/starry.pcap"
cp "$capture_prefix.vm2.pcap" "$output_dir/zephyr.pcap"
cp "$selected_zephyr_dir/manifest.toml" "$output_dir/zephyr-manifest.toml"
cp "$repo_root/scripts/test/net-dual-guest/qemu-aarch64-starry-zephyr-switch-msix1-capture.toml" "$output_dir/qemu.toml"
cp "$repo_root/scripts/test/net-dual-guest/vm-aarch64-starry-switch.toml" "$output_dir/vm-starry.toml"
cp "$repo_root/scripts/test/net-dual-guest/vm-aarch64-p2-switch-rtos.toml" "$output_dir/vm-zephyr.toml"

if [[ "$scenario" == model-rejected ]]; then
    pcap_requirements=(--tag '' --min-udp 2)
else
    pcap_requirements=(--tag '' --require-task2)
fi
python3 "$repo_root/scripts/test/net-dual-guest/verify_pcap.py" \
    "${pcap_requirements[@]}" "$output_dir/starry.pcap" "$output_dir/zephyr.pcap" \
    | tee "$output_dir/verify-pcap.log"
python3 "$repo_root/scripts/test/net-dual-guest/verify_starry_task23.py" \
    --scenario "$scenario" \
    --starry-pcap "$output_dir/starry.pcap" \
    --zephyr-pcap "$output_dir/zephyr.pcap" \
    --run-log "$run_log" | tee "$output_dir/verify-scenario.log"

{
    sha256sum "$rootfs"
    sha256sum "$endpoint"
    sha256sum "$starry_image"
    sha256sum "$selected_zephyr_dir/zephyr-task2.bin"
    sha256sum "$axvisor_image"
} > "$output_dir/artifact-hashes.txt"

find "$output_dir" -maxdepth 1 -type f ! -name SHA256SUMS.txt -print0 \
    | sort -z | xargs -0 sha256sum > "$output_dir/SHA256SUMS.txt"
printf 'PASS: evidence retained in %s\n' "$output_dir"
