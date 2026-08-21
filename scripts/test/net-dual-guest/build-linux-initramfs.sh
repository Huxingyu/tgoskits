#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
base_initramfs="${BASE_INITRAMFS:-/home/huhu/tgoskits-realtime/tmp/initramfs-custom}"
task2_binary="${TASK2_BINARY:-$repo_root/tmp/net-dual-guest/linux-task2/controller/task2-net}"
model_dir="${TASK3_NCNN_MODEL_DIR:-$repo_root/tmp/task3-yolo/ncnn-model}"
out_dir="${OUT_DIR:-$repo_root/tmp/net-dual-guest/linux-task2}"
out_file="$out_dir/task2-linux-initramfs.cpio.gz"
template="$repo_root/scripts/test/net-dual-guest/linux-init.sh"

for input in "$base_initramfs" "$task2_binary" "$template"; do
    if [[ ! -f "$input" ]]; then
        printf 'error: required input is missing: %s\n' "$input" >&2
        exit 1
    fi
done
mkdir -p "$out_dir"
root_dir="$(mktemp -d /tmp/task2-initramfs-root.XXXXXX)"
trap 'rm -rf "$root_dir"' EXIT

gzip -dc "$base_initramfs" | (cd "$root_dir" && cpio -idm --quiet)
install -m 0755 "$task2_binary" "$root_dir/bin/task2-net"
install -m 0755 "$template" "$root_dir/init"
if [[ "${TASK3_MODEL:-}" == "yolo" ]]; then
    for model_file in yolo11n.ncnn.param yolo11n.ncnn.bin input.ppm; do
        if [[ ! -f "$model_dir/$model_file" ]]; then
            printf 'error: YOLO ncnn asset is missing: %s\n' "$model_dir/$model_file" >&2
            exit 1
        fi
    done
    install -d "$root_dir/usr/share/task3-yolo"
    install -m 0644 "$model_dir/yolo11n.ncnn.param" "$root_dir/usr/share/task3-yolo/yolo11n.ncnn.param"
    install -m 0644 "$model_dir/yolo11n.ncnn.bin" "$root_dir/usr/share/task3-yolo/yolo11n.ncnn.bin"
    install -m 0644 "$model_dir/input.ppm" "$root_dir/usr/share/task3-yolo/input.ppm"
fi

(cd "$root_dir" && find . -print | cpio -o -H newc --quiet) | gzip -n -9 > "$out_file"
sha256sum "$out_file" | awk '{print $1}' > "$out_file.sha256"
printf 'initramfs=%s sha256=%s\n' "$out_file" "$(cat "$out_file.sha256")"
