#!/usr/bin/env bash
# Repack the task-2 initramfs with the udp_probe tool added.
#
# Output is written to tmp/net-dual-guest, never overwrites the base image.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INITRAMFS_REL="tmp/axbuild/rootfs/initramfs-aarch64-busybox.cpio.gz/initramfs-aarch64-busybox.cpio.gz"
BASE_INITRAMFS="${BASE_INITRAMFS:-}"
if [[ -z "$BASE_INITRAMFS" ]]; then
  if [[ -f "$REPO_ROOT/$INITRAMFS_REL" ]]; then
    BASE_INITRAMFS="$REPO_ROOT/$INITRAMFS_REL"
  elif [[ -f "$HOME/tgoskits/$INITRAMFS_REL" ]]; then
    BASE_INITRAMFS="$HOME/tgoskits/$INITRAMFS_REL"
  fi
fi
PROBE="${PROBE:-$REPO_ROOT/tmp/net-dual-guest/udp_probe}"
TASK2_INIT="${TASK2_INIT:-$REPO_ROOT/tmp/net-dual-guest/task2-init}"
OUT="${OUT_INITRAMFS:-$REPO_ROOT/tmp/net-dual-guest/initramfs-aarch64-busybox-net.cpio.gz}"

if [[ ! -f "$BASE_INITRAMFS" ]]; then
  echo "base initramfs not found: $BASE_INITRAMFS" >&2
  exit 1
fi
if [[ ! -x "$PROBE" ]]; then
  echo "udp_probe not found; run build-udp-probe.sh first: $PROBE" >&2
  exit 1
fi
if [[ ! -x "$TASK2_INIT" ]]; then
  echo "task2-init not found; run build-udp-probe.sh first: $TASK2_INIT" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/udp-initramfs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
gzip -dc "$BASE_INITRAMFS" | cpio -idm --quiet
cp "$PROBE" bin/udp_probe
chmod 0755 bin/udp_probe
cp "$TASK2_INIT" bin/task2-init
chmod 0755 bin/task2-init
mkdir -p "$(dirname "$OUT")"
find . -print0 | cpio -o -0 -H newc --quiet | gzip -9 > "$OUT"

echo "packed: $OUT"
