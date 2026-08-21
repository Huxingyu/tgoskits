#!/usr/bin/env bash
set -euo pipefail

app_dir="${STARRY_APP_DIR:?prebuild: STARRY_APP_DIR is required}"
overlay_dir="${STARRY_OVERLAY_DIR:?prebuild: STARRY_OVERLAY_DIR is required}"
arch="${STARRY_ARCH:?prebuild: STARRY_ARCH is required}"
workspace="${STARRY_WORKSPACE:?prebuild: STARRY_WORKSPACE is required}"

case "$arch" in
    aarch64) triple="aarch64-linux-musl" ;;
    *) echo "prebuild: starryos-task2 currently supports only aarch64" >&2; exit 1 ;;
esac

cc="${CROSS_CC:-/home/huhu/.local/toolchains/${triple}-cross/bin/${triple}-gcc}"
if [[ ! -x "$cc" ]]; then
    if command -v "${triple}-gcc" >/dev/null 2>&1; then
        cc="$(command -v "${triple}-gcc")"
    else
        echo "prebuild: no musl compiler for $triple" >&2
        exit 1
    fi
fi

build_dir="$workspace/target/starryos-task2-rust"
rm -rf "$build_dir"
mkdir -p "$build_dir"
linker_dir="$build_dir/linker"
mkdir -p "$linker_dir"
ln -sf "$cc" "$linker_dir/aarch64-unknown-linux-musl-ld"

CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$cc" \
RUSTFLAGS="-C target-feature=+crt-static" \
cargo build --release --target aarch64-unknown-linux-musl \
    --manifest-path "$app_dir/rust/Cargo.toml" --target-dir "$build_dir"
out="$build_dir/aarch64-unknown-linux-musl/release/starryos-task2-endpoint"
test -x "$out"

install -Dm0755 "$out" "$overlay_dir/usr/bin/starry-udp-probe"
install -Dm0755 "$app_dir/udp-probe.sh" "$overlay_dir/usr/bin/starry-udp-probe.sh"
install -Dm0755 "$out" "$overlay_dir/usr/bin/starry-t2n1-endpoint"
install -Dm0755 "$app_dir/t2n1-run.sh" "$overlay_dir/usr/bin/t2n1-run.sh"
echo "prebuild: starryos-task2 UDP probe built for $arch"
