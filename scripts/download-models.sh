#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODEL_DIR="${PROJECT_DIR}/modules/react-native-clear-ahead-vision/models"
TEMP_DIR="$(mktemp -d /tmp/clear-ahead-models.XXXXXX)"

trap 'rm -rf "${TEMP_DIR}"' EXIT

YOLO_URL="https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel"
YOLO_SHA="cde8af2528d6eca1d1580fdd0f0147cb6613d40ba962656b5f683c65f571870e"
DEPTH_URL="https://ml-assets.apple.com/coreml/models/Image/DepthEstimation/DepthAnything/DepthAnythingV2SmallF16P6.mlpackage.zip"
DEPTH_SHA="0268456a2c388d73bc36ef8e8e2d7ecffbbb6afeb1d73e79030c84cb5e7f3594"

mkdir -p "${MODEL_DIR}"

download_and_verify() {
  local url="$1"
  local destination="$2"
  local expected_sha="$3"
  curl --fail --location --silent --show-error "${url}" --output "${destination}"
  local actual_sha
  actual_sha="$(shasum -a 256 "${destination}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "Checksum mismatch for ${destination}" >&2
    exit 1
  fi
}

echo "Downloading Apple YOLOv3 Tiny Int8 model..."
download_and_verify \
  "${YOLO_URL}" \
  "${TEMP_DIR}/YOLOv3TinyInt8LUT.mlmodel" \
  "${YOLO_SHA}"

echo "Downloading Apple Depth Anything V2 Small P6 model..."
download_and_verify \
  "${DEPTH_URL}" \
  "${TEMP_DIR}/DepthAnythingV2SmallF16P6.mlpackage.zip" \
  "${DEPTH_SHA}"

cp "${TEMP_DIR}/YOLOv3TinyInt8LUT.mlmodel" "${MODEL_DIR}/YOLOv3TinyInt8LUT.mlmodel"
rm -rf "${MODEL_DIR}/DepthAnythingV2SmallF16P6.mlpackage"
unzip -q "${TEMP_DIR}/DepthAnythingV2SmallF16P6.mlpackage.zip" -d "${MODEL_DIR}"
rm -rf "${MODEL_DIR}/__MACOSX"

echo "Models installed in ${MODEL_DIR}"
