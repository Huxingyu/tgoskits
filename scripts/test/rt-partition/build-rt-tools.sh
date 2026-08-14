#!/usr/bin/env bash
set -euo pipefail

# Build static cyclictest (rt-tests) and stress-ng for aarch64 musl and pack
# them into the Linux initramfs used by the RT-partition measurement flow.
#
# Source trees are expected under SRC_ROOT (default ~/.local/src):
#   rt-tests/            https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git
#   numactl-2.0.18/      https://github.com/numactl/numactl/releases/tag/v2.0.18
#   stress-ng/           https://github.com/ColinIanKing/stress-ng
#
# Outputs:
#   tmp/rt-partition/tools/cyclictest
#   tmp/rt-partition/tools/stress-ng
#   tmp/rt-partition/rt-linux-initramfs.cpio.gz   (busybox rootfs + tools + init)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
out_dir="${OUT_DIR:-$repo_root/tmp/rt-partition}"
src_root="${SRC_ROOT:-$HOME/.local/src}"
cross_cc="${CROSS_CC:-$HOME/.local/toolchains/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc}"
rt_tests_src="${RTTESTS_SRC:-$src_root/rt-tests}"
numa_src="${NUMA_SRC:-$src_root/numactl-2.0.18}"
stress_ng_src="${STRESS_NG_SRC:-$src_root/stress-ng}"
base_initramfs="${BASE_INITRAMFS:-$HOME/tgoskits-realtime/tmp/initramfs-custom}"

for path in "$cross_cc" "$rt_tests_src" "$numa_src" "$stress_ng_src" "$base_initramfs"; do
    [[ -e "$path" ]] || {
        printf 'error: required input is missing: %s\n' "$path" >&2
        exit 1
    }
done

mkdir -p "$out_dir/tools"
export PATH="$(dirname "$cross_cc"):$PATH"

# --- cyclictest (rt-tests) ------------------------------------------------
if [[ ! -x "$out_dir/tools/cyclictest" ]]; then
    printf 'building cyclictest from %s\n' "$rt_tests_src"
    make -C "$rt_tests_src" clean >/dev/null 2>&1 || true
    make -C "$rt_tests_src" cyclictest \
        CC="$(basename "$cross_cc")" \
        LDFLAGS="-static" \
        CPPFLAGS="-D_GNU_SOURCE -Isrc/include -I$numa_src" \
        RTTESTNUMA="-lrttestnuma -Lbld -lnuma -L$numa_src/.libs"
    cp "$rt_tests_src/cyclictest" "$out_dir/tools/cyclictest"
    chmod 0755 "$out_dir/tools/cyclictest"
    printf 'cyclictest=%s\n' "$out_dir/tools/cyclictest"
fi

# --- stress-ng -------------------------------------------------------------
if [[ ! -x "$out_dir/tools/stress-ng" ]]; then
    printf 'building stress-ng from %s\n' "$stress_ng_src"
    make -C "$stress_ng_src" clean >/dev/null 2>&1 || true
    make -C "$stress_ng_src" STATIC=1 CC="$(basename "$cross_cc")" -j"$(nproc)"
    cp "$stress_ng_src/stress-ng" "$out_dir/tools/stress-ng"
    chmod 0755 "$out_dir/tools/stress-ng"
    printf 'stress-ng=%s\n' "$out_dir/tools/stress-ng"
fi

# --- pack initramfs ---------------------------------------------------------
root_dir="$(mktemp -d /tmp/rt-initramfs-root.XXXXXX)"
trap 'rm -rf "$root_dir"' EXIT

gzip -dc "$base_initramfs" | (cd "$root_dir" && cpio -idm --quiet)
install -m 0755 "$out_dir/tools/cyclictest" "$root_dir/bin/cyclictest"
install -m 0755 "$out_dir/tools/stress-ng" "$root_dir/bin/stress-ng"
install -m 0755 "$repo_root/scripts/test/rt-partition/rt-linux-init.sh" "$root_dir/init"

out_file="$out_dir/rt-linux-initramfs.cpio.gz"
(cd "$root_dir" && find . -print | cpio -o -H newc --quiet) | gzip -n -9 > "$out_file"
sha256sum "$out_file" | awk '{print $1}' > "$out_file.sha256"
printf 'initramfs=%s sha256=%s\n' "$out_file" "$(cat "$out_file.sha256")"
