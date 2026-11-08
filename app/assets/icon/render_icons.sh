#!/usr/bin/env bash
# 一键重新生成 iOS / Android 全套应用图标（唯一设计真源：app_icon.svg）
#
# 依赖：rsvg-convert（brew install librsvg）、python3（标准库即可）
# 用法：bash app/assets/icon/render_icons.sh
#
# 生成物：
#   iOS     ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png（15 张，无 alpha）
#   Android android/app/src/main/res/mipmap-*/ic_launcher.png（48/72/96/144/192，无 alpha）
#           android/app/src/main/res/mipmap-*/ic_launcher_foreground.png（自适应图标前景，108dp 基准）
#           android/app/src/main/res/mipmap-*/ic_launcher_monochrome.png（Android 13+ 主题图标）
#           android/app/src/main/res/drawable-xxhdpi/rc_splash_logo.png（旧系统启动屏标识）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${HERE}/../.." && pwd)"
RSVG="${RSVG_CONVERT:-/opt/homebrew/bin/rsvg-convert}"
STRIP="${HERE}/strip_alpha.py"

IOS_DIR="${APP_DIR}/ios/Runner/Assets.xcassets/AppIcon.appiconset"
RES_DIR="${APP_DIR}/android/app/src/main/res"

[[ -x "${RSVG}" ]] || { echo "找不到 rsvg-convert：${RSVG}" >&2; exit 1; }
mkdir -p "${IOS_DIR}" "${RES_DIR}/drawable-xxhdpi"

# 渲染：$1=源 svg $2=目标 png $3=边长
render_raw() { "${RSVG}" -w "$3" -h "$3" -o "$2" "$1"; }

# 渲染并去掉 alpha 通道（iOS 图标硬性要求）
render_rgb() {
  local tmp
  tmp="$(mktemp -t rcicon).png"
  render_raw "$1" "${tmp}" "$3"
  python3 "${STRIP}" "${tmp}" "$2"
  rm -f "${tmp}"
}

echo "==> iOS AppIcon"
while read -r file size; do
  render_rgb "${HERE}/app_icon.svg" "${IOS_DIR}/${file}" "${size}"
  echo "    ${file}  ${size}x${size}"
done <<'EOF'
Icon-App-20x20@1x.png 20
Icon-App-20x20@2x.png 40
Icon-App-20x20@3x.png 60
Icon-App-29x29@1x.png 29
Icon-App-29x29@2x.png 58
Icon-App-29x29@3x.png 87
Icon-App-40x40@1x.png 40
Icon-App-40x40@2x.png 80
Icon-App-40x40@3x.png 120
Icon-App-60x60@2x.png 120
Icon-App-60x60@3x.png 180
Icon-App-76x76@1x.png 76
Icon-App-76x76@2x.png 152
Icon-App-83.5x83.5@2x.png 167
Icon-App-1024x1024@1x.png 1024
EOF

echo "==> Android 传统图标（ic_launcher）"
while read -r bucket size; do
  mkdir -p "${RES_DIR}/mipmap-${bucket}"
  render_rgb "${HERE}/app_icon.svg" "${RES_DIR}/mipmap-${bucket}/ic_launcher.png" "${size}"
  echo "    mipmap-${bucket}/ic_launcher.png  ${size}x${size}"
done <<'EOF'
mdpi 48
hdpi 72
xhdpi 96
xxhdpi 144
xxxhdpi 192
EOF

echo "==> Android 自适应图标（前景 / 主题图标，保留透明通道）"
while read -r bucket size; do
  render_raw "${HERE}/app_icon_foreground.svg" \
    "${RES_DIR}/mipmap-${bucket}/ic_launcher_foreground.png" "${size}"
  render_raw "${HERE}/app_icon_monochrome.svg" \
    "${RES_DIR}/mipmap-${bucket}/ic_launcher_monochrome.png" "${size}"
  echo "    mipmap-${bucket}/ic_launcher_*.png  ${size}x${size}"
done <<'EOF'
mdpi 108
hdpi 162
xhdpi 216
xxhdpi 324
xxxhdpi 432
EOF

echo "==> Android 启动屏标识"
# 放 xxhdpi：384px = 128dp，其它密度由系统缩放，启动屏上大小稳定
render_raw "${HERE}/app_icon_splash.svg" "${RES_DIR}/drawable-xxhdpi/rc_splash_logo.png" 384
echo "    drawable-xxhdpi/rc_splash_logo.png  384px = 128dp"

echo "完成。请用 file / md5 抽查产物，并在模拟器上确认图标不是 Flutter 模板图。"
