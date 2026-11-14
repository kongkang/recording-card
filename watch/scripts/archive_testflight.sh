#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$WATCH_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/RecordingCardWatch.xcarchive"
EXPORT_DIR="$BUILD_DIR/ipa"
UPLOAD=false

for arg in "$@"; do
  case "$arg" in
    --upload)
      UPLOAD=true
      ;;
    *)
      echo "未知参数: $arg (支持 --upload)" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

echo "==> [1/3] 校验 WatchRecorderCore 共享核心包..."
swift test --package-path "$WATCH_DIR/Packages/WatchRecorderCore"
swift run --package-path "$WATCH_DIR/Packages/WatchRecorderCore" WatchRecorderCoreVerify

echo "==> [2/3] 归档 RecordingCardWatchCompanion（内嵌 WatchApp + WatchWidgets）..."
xcodebuild archive \
  -project "$WATCH_DIR/RecordingCardWatch.xcodeproj" \
  -scheme RecordingCardWatchCompanion \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates

echo "==> [3/3] 导出 App Store Connect / TestFlight 包..."
EXPORT_PLIST="$WATCH_DIR/ExportOptions.plist"
if [ "$UPLOAD" = true ]; then
  TEMP_PLIST="$BUILD_DIR/ExportOptions.upload.plist"
  sed 's/<string>export<\/string>/<string>upload<\/string>/' "$EXPORT_PLIST" > "$TEMP_PLIST"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$TEMP_PLIST" \
    -allowProvisioningUpdates
  echo "✅ 已触发上传至 App Store Connect / TestFlight。"
else
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates
  echo "✅ IPA 已导出至: $EXPORT_DIR"
  echo "   若需直接上传，请运行: $0 --upload"
fi
