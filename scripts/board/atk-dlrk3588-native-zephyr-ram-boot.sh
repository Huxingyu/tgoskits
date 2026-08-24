#!/usr/bin/env bash
# Start the pinned native Zephyr BL33 through the RK3588 RAMBOOT protocol.
#
# The two `write` commands below target RAMBOOT loader staging slots. This
# script never invokes a flash, erase, partition, GPT, or upgrade operation.

set -euo pipefail

readonly RAMBOOT_LOADER_SHA256=77946243210318fea16ba4e04a22e7d18a5348cfd1328ef4accb3bb4bb5a7787
readonly TRUST_IMAGE_SHA256=754383b8bfb15f6e7ab7616a03bad8054cae7ca9701519bc7349b9cc9fb0c73d
readonly EVIDENCE_BL33_SHA256=59ef4dd3ffab6a0d767755cc3822d67a5047cfa227c338e2312fa062ff01fd1d
readonly RKDEVELOPTOOL_SHA256=47048ad3caf253945def1ac11641c30a49d8160abb26c0618d06f6727be26836
readonly EXECUTE_TOOL_SHA256=e285dffbca73d032da13c8ed58536189e090a6adc5868f06973c7563850a31dc
readonly BL33_SLOT=0x2000
readonly TRUST_SLOT=0x4000
readonly EXECUTE_SUBCODE=0xaa

rkdeveloptool="${RKDEVELOPTOOL:-rkdeveloptool}"
execute_tool="${RKDEVELOPTOOL_ES:-}"
ramboot_loader="${ATK_RAMBOOT_LOADER:-}"
bl33_image="${ATK_NATIVE_BL33:-}"
trust_image="${ATK_NATIVE_TRUST:-}"
expected_bl33_sha256="${ATK_NATIVE_BL33_SHA256:-$EVIDENCE_BL33_SHA256}"
adb_reboot=true

main() {
	parse_arguments "$@"
	resolve_tools
	verify_inputs
	enter_rockusb
	start_ramboot_loader
	stage_native_images
	printf 'executing upstream BL31 and native Zephyr from RAM\n'
	"$execute_tool" es "$EXECUTE_SUBCODE"
}

usage() {
	cat <<'EOF'
Usage: atk-dlrk3588-native-zephyr-ram-boot.sh [options]

Required:
  --loader FILE       pinned RK3588 RAMBOOT loader
  --bl33 FILE         loaderimage-wrapped Zephyr BL33
  --trust FILE        pinned upstream TF-A BL31 trust image
  --execute-tool FILE rkdeveloptool 1.3 binary with ExecuteSDRAM support

Options:
  --rkdeveloptool FILE  rkdeveloptool 1.0.0 command (default: PATH)
  --bl33-sha256 HASH    expected BL33 identity (default: accepted evidence)
  --no-adb-reboot       require the board to already be in rockusb mode
  -h, --help            show this help

The required paths may instead be supplied with ATK_RAMBOOT_LOADER,
ATK_NATIVE_BL33, ATK_NATIVE_TRUST, and RKDEVELOPTOOL_ES.
EOF
}

parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--loader)
			require_option_value "$1" "${2:-}"
			ramboot_loader="$2"
			shift 2
			;;
		--bl33)
			require_option_value "$1" "${2:-}"
			bl33_image="$2"
			shift 2
			;;
		--trust)
			require_option_value "$1" "${2:-}"
			trust_image="$2"
			shift 2
			;;
		--execute-tool)
			require_option_value "$1" "${2:-}"
			execute_tool="$2"
			shift 2
			;;
		--rkdeveloptool)
			require_option_value "$1" "${2:-}"
			rkdeveloptool="$2"
			shift 2
			;;
		--bl33-sha256)
			require_option_value "$1" "${2:-}"
			expected_bl33_sha256="$2"
			shift 2
			;;
		--no-adb-reboot)
			adb_reboot=false
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

resolve_tools() {
	local resolved
	resolved="$(command -v "$rkdeveloptool" 2>/dev/null || true)"
	if [[ -z "$resolved" ]]; then
		printf 'error: rkdeveloptool is unavailable: %s\n' "$rkdeveloptool" >&2
		exit 1
	fi
	rkdeveloptool="$resolved"
	if [[ -z "$execute_tool" || ! -x "$execute_tool" ]]; then
		printf 'error: --execute-tool must name an executable file\n' >&2
		exit 2
	fi
	if ! command -v sha256sum >/dev/null 2>&1; then
		printf 'error: sha256sum is unavailable\n' >&2
		exit 1
	fi
}

verify_inputs() {
	verify_regular_file "$ramboot_loader" "RAMBOOT loader"
	verify_regular_file "$bl33_image" "BL33 image"
	verify_regular_file "$trust_image" "BL31 trust image"
	verify_sha256 "$rkdeveloptool" "$RKDEVELOPTOOL_SHA256" "rkdeveloptool 1.0.0"
	verify_sha256 "$execute_tool" "$EXECUTE_TOOL_SHA256" "rkdeveloptool 1.3"
	verify_sha256 "$ramboot_loader" "$RAMBOOT_LOADER_SHA256" "RAMBOOT loader"
	verify_sha256 "$trust_image" "$TRUST_IMAGE_SHA256" "BL31 trust image"
	verify_sha256 "$bl33_image" "$expected_bl33_sha256" "Zephyr BL33 image"
}

verify_regular_file() {
	if [[ -z "$1" || ! -f "$1" ]]; then
		printf 'error: %s is not a regular file: %s\n' "$2" "$1" >&2
		exit 2
	fi
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

enter_rockusb() {
	if rockusb_mode_is Maskrom; then
		printf 'board is already in Maskrom mode\n'
		return
	fi
	if ! rockusb_device_present; then
		if [[ "$adb_reboot" != true ]]; then
			printf 'error: no rockusb device and ADB reboot is disabled\n' >&2
			exit 1
		fi
		if ! command -v adb >/dev/null 2>&1 || ! adb get-state >/dev/null 2>&1; then
			printf 'error: board is visible through neither rockusb nor ADB\n' >&2
			exit 1
		fi
		printf 'rebooting vendor system into rockusb loader mode\n'
		adb reboot loader
		wait_for_rockusb_mode Loader 30
	fi
	printf 'switching the board from loader to Maskrom mode\n'
	"$rkdeveloptool" reboot-maskrom
	wait_for_rockusb_mode Maskrom 30
}

start_ramboot_loader() {
	printf 'starting pinned RK3588 RAMBOOT loader\n'
	"$rkdeveloptool" boot "$ramboot_loader"
	wait_for_rockusb_mode Loader 30
}

stage_native_images() {
	printf 'staging BL33 in RAMBOOT slot %s\n' "$BL33_SLOT"
	"$rkdeveloptool" write "$BL33_SLOT" "$bl33_image"
	printf 'staging BL31 trust image in RAMBOOT slot %s\n' "$TRUST_SLOT"
	"$rkdeveloptool" write "$TRUST_SLOT" "$trust_image"
}

rockusb_device_present() {
	rockusb_list | grep -q 'Mode='
}

rockusb_mode_is() {
	local expected_mode="$1"
	local device_list device_count
	device_list="$(rockusb_list)"
	device_count="$(grep -c 'Mode=' <<<"$device_list" || true)"
	if [[ "$device_count" -gt 1 ]]; then
		printf 'error: multiple rockusb devices are present; refusing an ambiguous write\n' >&2
		exit 1
	fi
	[[ "$device_count" -eq 1 ]] && grep -q "Mode=$expected_mode" <<<"$device_list"
}

rockusb_list() {
	"$rkdeveloptool" list 2>/dev/null || true
}

wait_for_rockusb_mode() {
	local expected_mode="$1"
	local timeout_seconds="$2"
	local elapsed
	for ((elapsed = 0; elapsed < timeout_seconds; ++elapsed)); do
		if rockusb_mode_is "$expected_mode"; then
			return
		fi
		sleep 1
	done
	printf 'error: board did not enter %s mode within %ss\n' \
		"$expected_mode" "$timeout_seconds" >&2
	exit 1
}

main "$@"
