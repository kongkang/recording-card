#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$WATCH_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
BUILD_DIR="$WATCH_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Runner.xcarchive"
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

FLUTTER_BIN="${FLUTTER_BIN:-}"
if [ -z "$FLUTTER_BIN" ]; then
  if [ -x "$ROOT_DIR/.work/tools/flutter/bin/flutter" ]; then
    FLUTTER_BIN="$ROOT_DIR/.work/tools/flutter/bin/flutter"
  else
    FLUTTER_BIN="$(command -v flutter || true)"
  fi
fi
if [ -z "$FLUTTER_BIN" ]; then
  echo "未找到 flutter 可执行文件，请设置 FLUTTER_BIN 或将其加入 PATH" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

echo "==> [1/5] 校验 WatchRecorderCore 共享核心包..."
swift test --package-path "$WATCH_DIR/Packages/WatchRecorderCore"
swift run --package-path "$WATCH_DIR/Packages/WatchRecorderCore" WatchRecorderCoreVerify

echo "==> [2/5] 构建 iOS Rust 硬件桥（如本机具备工具链）..."
if [ -x "$APP_DIR/rust/build-ios.sh" ]; then
  (cd "$APP_DIR/rust" && ./build-ios.sh)
fi

echo "==> [3/5] 准备 Flutter iOS 工程与 CocoaPods..."
(cd "$APP_DIR" && "$FLUTTER_BIN" pub get && "$FLUTTER_BIN" build ios --config-only --release --no-codesign)

echo "==> [4/5] 归档统一主端 Runner（内嵌 RecordingCardWatchApp + RecordingCardWatchWidgets）..."
xcodebuild archive \
  -workspace "$APP_DIR/ios/Runner.xcworkspace" \
  -scheme Runner \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates

WATCH_APP="$ARCHIVE_PATH/Products/Applications/Runner.app/Watch/RecordingCardWatchApp.app"
WIDGET_APPEX="$WATCH_APP/PlugIns/RecordingCardWatchWidgets.appex"
test -d "$WATCH_APP"
test -d "$WIDGET_APPEX"

echo "==> [5/5] 导出 App Store Connect / TestFlight 包..."
EXPORT_PLIST="$WATCH_DIR/ExportOptions.plist"
if [ "$UPLOAD" = true ]; then
  TEMP_PLIST="$BUILD_DIR/ExportOptions.upload.plist"
  sed 's/<string>export<\/string>/<string>upload<\/string>/' "$EXPORT_PLIST" > "$TEMP_PLIST"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$TEMP_PLIST" \
    -allowProvisioningUpdates
  echo "✅ 已触发上传统一主端 IPA 至 App Store Connect / TestFlight。"
else
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates
  echo "✅ 统一主端 IPA 已导出至: $EXPORT_DIR"
  echo "   若需直接上传，请运行: $0 --upload"
fi
