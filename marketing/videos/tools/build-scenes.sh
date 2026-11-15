#!/bin/bash
# 10 条实拍场景宣传片构建：界面全部来自 prototype/index.html 真实截图（ui-shots.ts）
# 用法：./build-scenes.sh [all|s01..s10]
set -e
cd "$(dirname "$0")"
OUT=../out

IDS=(sd1 sd2 sd3 sd4 sd5 sd6 sd7 sd8 sd9 sd10)
NAMES=(s01-meeting s02-minutes s03-interview s04-offline s05-raw s06-family s07-care s08-class s09-podcast s10-unbox)

# 界面截图（原型只读驱动实截）
if [ ! -f ui/live-feed.png ]; then bun ui-shots.ts; fi
# 配乐
bun music.ts scene

ONLY=${1:-all}
n=${#IDS[@]}
for ((i=0; i<n; i++)); do
  id=${IDS[$i]}; name=${NAMES[$i]}
  if [ "$ONLY" != "all" ] && [ "${name%%-*}" != "$ONLY" ]; then continue; fi
  echo "== capture $id =="
  bun capture.ts "$id" 30 | tail -1
  echo "== encode $name =="
  swift encode.swift --frames "/tmp/rc-promo/frames/$id" --fps 30 \
    --audio /tmp/rc-promo/music/scene.wav --out "$OUT/$name.mp4" | tail -1
done
echo "== done =="
ls -la "$OUT"
