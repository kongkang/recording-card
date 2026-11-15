#!/bin/bash
# 录音卡宣传视频一键构建：渲染帧 → 配乐 → 编码 MP4
# 依赖：bun（截帧/配乐）、swift+AVFoundation（编码）、Google Chrome（headless 渲染）
set -e
cd "$(dirname "$0")"

declare -A NAMES=( [v1]=v1-office [v2]=v2-privacy [v3]=v3-family [v4]=v4-student [v5]=v5-launch )
ONLY=${1:-}

mkdir -p out
for v in v1 v2 v3 v4 v5; do
  if [ -n "$ONLY" ] && [ "$v" != "$ONLY" ]; then continue; fi
  echo "== capture $v =="
  bun capture.ts "$v" 30
done
echo "== music =="
bun music.ts
for v in v1 v2 v3 v4 v5; do
  if [ -n "$ONLY" ] && [ "$v" != "$ONLY" ]; then continue; fi
  echo "== encode $v =="
  swift encode.swift --frames "/tmp/rc-promo/frames/$v" --fps 30 \
    --audio "/tmp/rc-promo/music/$v.wav" --out "out/${NAMES[$v]}.mp4"
done
echo "== done =="
ls -la out/
