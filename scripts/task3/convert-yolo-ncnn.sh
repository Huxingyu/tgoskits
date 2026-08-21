#!/usr/bin/env bash
set -euo pipefail

# Convert the pinned YOLO11n ONNX artifact to ncnn's param/bin format.
# PNNX is a host-side conversion tool; the resulting param/bin files are the
# artifacts loaded by the Linux Guest ncnn runtime.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
model="${YOLO_ONNX:-$repo_root/tmp/task3-yolo/yolo11n.onnx}"
out_dir="${OUT_DIR:-$repo_root/tmp/task3-yolo/ncnn-model}"
pnnx_bin="${PNNX:-}"
expected_sha="634279b40c07c6391472c51ad45b81ebc48706a9a1fe72dd3396322acd0c053b"

if [[ ! -f "$model" ]]; then
    printf 'error: missing YOLO ONNX model: %s\n' "$model" >&2
    exit 2
fi
actual_sha="$(sha256sum "$model" | awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
    printf 'error: YOLO ONNX hash mismatch: expected %s got %s\n' "$expected_sha" "$actual_sha" >&2
    exit 2
fi
if [[ -z "$pnnx_bin" || ! -x "$pnnx_bin" ]]; then
    printf 'error: PNNX must point to the host converter executable\n' >&2
    exit 2
fi

mkdir -p "$out_dir"
cp "$model" "$out_dir/yolo11n.onnx"
(cd "$out_dir" && "$pnnx_bin" yolo11n.onnx \
    inputshape='[1,3,640,640]f32' \
    inputshape2='[1,3,640,640]f32' \
    optlevel=2)

test -s "$out_dir/yolo11n.ncnn.param"
test -s "$out_dir/yolo11n.ncnn.bin"
model_sha="$(sha256sum "$out_dir/yolo11n.ncnn.bin" | awk '{print $1}')"
cat > "$out_dir/manifest.toml" <<EOF
source_onnx_sha256 = "$actual_sha"
input_shape = "1,3,640,640"
ncnn_param = "yolo11n.ncnn.param"
ncnn_bin = "yolo11n.ncnn.bin"
ncnn_bin_sha256 = "$model_sha"
EOF
printf 'param=%s\nbin=%s\nmanifest=%s\n' \
    "$out_dir/yolo11n.ncnn.param" "$out_dir/yolo11n.ncnn.bin" "$out_dir/manifest.toml"
