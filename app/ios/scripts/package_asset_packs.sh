#!/usr/bin/env bash
set -euo pipefail

# 将本地模型文件打包为 Apple-Hosted Background Assets (.aar) 归档，用于通过 altool / Transporter 上传至 App Store Connect。
#
# 用法：
#   ./package_asset_packs.sh <sensevoice_dir> [campplus_onnx_path] [output_dir]
#
# 示例：
#   ./package_asset_packs.sh \
#     "$HOME/Library/Application Support/reai-vibe-board/models/sensevoice-int8" \
#     "" \
#     "./build/asset-packs"

if [ "$#" -lt 1 ]; then
  echo "用法: $0 <sensevoice_dir> [campplus_onnx_path] [output_dir]" >&2
  exit 1
fi

SENSEVOICE_DIR="$(cd "$1" && pwd)"
CAMPPLUS_FILE="${2:-}"
OUTPUT_DIR="${3:-./build/asset-packs}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [ ! -f "$SENSEVOICE_DIR/model.int8.onnx" ] || [ ! -f "$SENSEVOICE_DIR/tokens.txt" ]; then
  echo "错误: $SENSEVOICE_DIR 下缺少 model.int8.onnx 或 tokens.txt" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/sensevoice-manifest.json" <<EOF
{
  "assetPackID": "sensevoice-small-int8",
  "downloadPolicy": {
    "onDemand": {}
  },
  "fileSelectors": [
    {
      "fileSource": "model.int8.onnx",
      "fileDestination": "sensevoice-small-int8/model.int8.onnx"
    },
    {
      "fileSource": "tokens.txt",
      "fileDestination": "sensevoice-small-int8/tokens.txt"
    }
  ],
  "platforms": [
    "iOS"
  ]
}
EOF

echo "正在打包 sensevoice-small-int8..."
(
  cd "$SENSEVOICE_DIR"
  xcrun ba-package package "$TMP_DIR/sensevoice-manifest.json" \
    --output-path "$OUTPUT_DIR/sensevoice-small-int8.aar"
)

if [ -n "$CAMPPLUS_FILE" ]; then
  if [ ! -f "$CAMPPLUS_FILE" ]; then
    echo "错误: 找不到声纹模型 $CAMPPLUS_FILE" >&2
    exit 1
  fi
  CAMPPLUS_DIR="$(cd "$(dirname "$CAMPPLUS_FILE")" && pwd)"
  CAMPPLUS_NAME="$(basename "$CAMPPLUS_FILE")"
  cat > "$TMP_DIR/campplus-manifest.json" <<EOF
{
  "assetPackID": "campplus-embedding",
  "downloadPolicy": {
    "onDemand": {}
  },
  "fileSelectors": [
    {
      "fileSource": "$CAMPPLUS_NAME",
      "fileDestination": "campplus-embedding/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    }
  ],
  "platforms": [
    "iOS"
  ]
}
EOF
  echo "正在打包 campplus-embedding..."
  (
    cd "$CAMPPLUS_DIR"
    xcrun ba-package package "$TMP_DIR/campplus-manifest.json" \
      --output-path "$OUTPUT_DIR/campplus-embedding.aar"
  )
fi

echo "打包完成："
ls -lh "$OUTPUT_DIR"/*.aar
