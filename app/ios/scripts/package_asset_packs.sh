#!/usr/bin/env bash
set -euo pipefail

# 将本地模型文件打包为 Apple-Hosted Background Assets (.aar) 归档，用于通过 altool / Transporter 上传至 App Store Connect。
# 打包前强制校验 SHA-256 与 asr_models.dart / model-manifest.json 官方规格一致。
#
# 用法：
#   ./package_asset_packs.sh <sensevoice_dir> <campplus_onnx_path> [output_dir]
#
# 示例：
#   ./package_asset_packs.sh \
#     "./sensevoice-small-int8" \
#     "./3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx" \
#     "./build/asset-packs"

if [ "$#" -lt 1 ]; then
  echo "用法: $0 <sensevoice_dir> [campplus_onnx_path] [output_dir]" >&2
  exit 1
fi

EXPECTED_SV_ONNX_SHA="c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"
EXPECTED_SV_TOKENS_SHA="f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
EXPECTED_CAMPPLUS_SHA="aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2"
EXPECTED_VAD_SHA="9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "错误: $file SHA-256 不匹配（期望 $expected，实际 $actual）" >&2
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SENSEVOICE_DIR="$(cd "$1" && pwd)"
CAMPPLUS_FILE="${2:-}"
OUTPUT_DIR="${3:-./build/asset-packs}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [ ! -f "$SENSEVOICE_DIR/model.int8.onnx" ] || [ ! -f "$SENSEVOICE_DIR/tokens.txt" ]; then
  echo "错误: $SENSEVOICE_DIR 下缺少 model.int8.onnx 或 tokens.txt" >&2
  exit 1
fi

verify_sha256 "$SENSEVOICE_DIR/model.int8.onnx" "$EXPECTED_SV_ONNX_SHA"
verify_sha256 "$SENSEVOICE_DIR/tokens.txt" "$EXPECTED_SV_TOKENS_SHA"

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
rm -f "$OUTPUT_DIR/sensevoice-small-int8.aar"
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
  verify_sha256 "$CAMPPLUS_FILE" "$EXPECTED_CAMPPLUS_SHA"
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
  rm -f "$OUTPUT_DIR/campplus-embedding.aar"
  (
    cd "$CAMPPLUS_DIR"
    xcrun ba-package package "$TMP_DIR/campplus-manifest.json" \
      --output-path "$OUTPUT_DIR/campplus-embedding.aar"
  )
fi

VAD_FILE="$SCRIPT_DIR/../../assets/models/silero_vad.onnx"
if [ -f "$VAD_FILE" ]; then
  verify_sha256 "$VAD_FILE" "$EXPECTED_VAD_SHA"
  VAD_DIR="$(cd "$(dirname "$VAD_FILE")" && pwd)"
  cat > "$TMP_DIR/silero-vad-manifest.json" <<EOF
{
  "assetPackID": "silero-vad",
  "downloadPolicy": {
    "onDemand": {}
  },
  "fileSelectors": [
    {
      "fileSource": "silero_vad.onnx",
      "fileDestination": "silero-vad/silero_vad.onnx"
    }
  ],
  "platforms": [
    "iOS"
  ]
}
EOF
  echo "正在打包 silero-vad..."
  rm -f "$OUTPUT_DIR/silero-vad.aar"
  (
    cd "$VAD_DIR"
    xcrun ba-package package "$TMP_DIR/silero-vad-manifest.json" \
      --output-path "$OUTPUT_DIR/silero-vad.aar"
  )
fi

echo "打包完成："
ls -lh "$OUTPUT_DIR"/*.aar
