#!/usr/bin/env bash
# Build the pinned native Zephyr periodic probe and wrap it as an RK3588 BL33.

set -euo pipefail

readonly ZEPHYR_COMMIT=dccb09599635bdff17633fa7e9dab014b91dce90
readonly LOADERIMAGE_SHA256=e26a311d449c6254d0d89ecaf8cd1870438205e07a66b27265d68830b8977439
readonly EVIDENCE_ZEPHYR_SHA256=5a22dec9b3b8f92f8b2ea9c5228c571236b2ae37b38300513d472622f212be4c
readonly EVIDENCE_BL33_SHA256=59ef4dd3ffab6a0d767755cc3822d67a5047cfa227c338e2312fa062ff01fd1d
readonly BL33_LOAD_ADDRESS=0x50000000
readonly BL33_IMAGE_SIZE_KIB=2048

app_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
patch_path="$app_dir/patches/0001-rk3588-map-uart2.patch"
zephyr_base="${ZEPHYR_BASE:-}"
loaderimage="${RK_LOADERIMAGE:-}"
build_dir="${NATIVE_ZEPHYR_BUILD_DIR:-$app_dir/build}"
output_dir="${NATIVE_ZEPHYR_OUTPUT_DIR:-$app_dir/out}"
apply_zephyr_patch=false

main() {
	parse_arguments "$@"
	require_inputs
	verify_zephyr_source
	ensure_uart2_patch
	verify_sha256 "$loaderimage" "$LOADERIMAGE_SHA256" "Rockchip loaderimage"
	build_zephyr
	pack_bl33
	verify_evidence_artifacts
	write_hash_manifest
	printf 'native Zephyr artifacts are ready in %s\n' "$output_dir"
}

usage() {
	cat <<'EOF'
Usage: build.sh --zephyr-base DIR --loaderimage FILE [options]

Required inputs may also be supplied as ZEPHYR_BASE and RK_LOADERIMAGE.

Options:
  --build-dir DIR       west build directory
  --output-dir DIR      BL33 and hash-manifest directory
  --apply-zephyr-patch  apply the pinned UART2 MMU patch when absent
  -h, --help            show this help
EOF
}

parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--zephyr-base)
			require_option_value "$1" "${2:-}"
			zephyr_base="$2"
			shift 2
			;;
		--loaderimage)
			require_option_value "$1" "${2:-}"
			loaderimage="$2"
			shift 2
			;;
		--build-dir)
			require_option_value "$1" "${2:-}"
			build_dir="$2"
			shift 2
			;;
		--output-dir)
			require_option_value "$1" "${2:-}"
			output_dir="$2"
			shift 2
			;;
		--apply-zephyr-patch)
			apply_zephyr_patch=true
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'error: unknown option: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
		esac
	done
}

require_option_value() {
	if [[ -z "$2" ]]; then
		printf 'error: %s requires a value\n' "$1" >&2
		exit 2
	fi
}

require_inputs() {
	local executable
	for executable in git sha256sum west; do
		if ! command -v "$executable" >/dev/null 2>&1; then
			printf 'error: required executable is unavailable: %s\n' "$executable" >&2
			exit 1
		fi
	done
	if [[ -z "$zephyr_base" ]] || \
		! git -C "$zephyr_base" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		printf 'error: --zephyr-base must name a Zephyr git checkout\n' >&2
		exit 2
	fi
	if [[ -z "$loaderimage" || ! -x "$loaderimage" ]]; then
		printf 'error: --loaderimage must name the executable Rockchip tool\n' >&2
		exit 2
	fi
}

verify_zephyr_source() {
	local actual_commit
	actual_commit="$(git -C "$zephyr_base" rev-parse HEAD)"
	if [[ "$actual_commit" != "$ZEPHYR_COMMIT" ]]; then
		printf 'error: Zephyr commit mismatch\n' >&2
		printf 'expected: %s\nactual:   %s\n' "$ZEPHYR_COMMIT" "$actual_commit" >&2
		exit 1
	fi
}

ensure_uart2_patch() {
	if git -C "$zephyr_base" apply --reverse --check "$patch_path" >/dev/null 2>&1; then
		printf 'Zephyr UART2 MMU patch is already present\n'
		return
	fi
	if ! git -C "$zephyr_base" apply --check "$patch_path"; then
		printf 'error: UART2 MMU patch neither applies nor is already present\n' >&2
		exit 1
	fi
	if [[ "$apply_zephyr_patch" != true ]]; then
		printf 'error: Zephyr needs the pinned UART2 MMU patch\n' >&2
		printf 'rerun with --apply-zephyr-patch, preferably in a dedicated checkout\n' >&2
		exit 1
	fi
	git -C "$zephyr_base" apply "$patch_path"
}

verify_sha256() {
	local path="$1"
	local expected="$2"
	local label="$3"
	local actual
	actual="$(sha256sum "$path")"
	actual="${actual%% *}"
	if [[ "$actual" != "$expected" ]]; then
		printf 'error: %s SHA256 mismatch\n' "$label" >&2
		printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
		exit 1
	fi
}

build_zephyr() {
	west build --pristine always \
		-b roc_rk3588_pc/rk3588 \
		-d "$build_dir" \
		"$app_dir"
}

pack_bl33() {
	local zephyr_bin="$build_dir/zephyr/zephyr.bin"
	mkdir -p "$output_dir"
	cp "$zephyr_bin" "$output_dir/zephyr.bin"
	"$loaderimage" --pack --uboot \
		"$output_dir/zephyr.bin" \
		"$output_dir/zephyr-native-periodic-bl33.img" \
		"$BL33_LOAD_ADDRESS" \
		--size "$BL33_IMAGE_SIZE_KIB" 1
}

verify_evidence_artifacts() {
	verify_sha256 "$output_dir/zephyr.bin" \
		"$EVIDENCE_ZEPHYR_SHA256" "Zephyr binary"
	verify_sha256 "$output_dir/zephyr-native-periodic-bl33.img" \
		"$EVIDENCE_BL33_SHA256" "BL33 image"
}

write_hash_manifest() {
	(
		cd "$output_dir"
		sha256sum zephyr.bin zephyr-native-periodic-bl33.img >SHA256SUMS.txt
	)
}

main "$@"
