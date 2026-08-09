#!/usr/bin/env bash
# Build the static aarch64 UDP probe used by the task-2 network smoke test.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CC="${CROSS_CC:-/home/huhu/.local/toolchains/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/tmp/net-dual-guest}"

mkdir -p "$OUT_DIR"
"$CC" -static -no-pie -O2 -Wall -Wextra -s -o "$OUT_DIR/udp_probe" \
  "$REPO_ROOT/scripts/test/net-dual-guest/udp_probe.c"
"$CC" -static -no-pie -O2 -Wall -Wextra -s -o "$OUT_DIR/task2-init" \
  "$REPO_ROOT/scripts/test/net-dual-guest/task2-init.c"
echo "built: $OUT_DIR/udp_probe"
echo "built: $OUT_DIR/task2-init"
