# 录音卡 · 宣传视频（5 条风格片 + 10 条场景片，16:9 1080p30，含配乐）

依据 `brief.md`（调研 + 分镜 + 事实红线）制作。每条都遵循「3 秒钩子 → 痛点 → 方案演示 → 佐证 → 单一 CTA」结构，完播友好时长。

## 场景系列（`out/s01–s10.mp4`，12s，2026-11-13 新增）

10 个实拍场景对应的简单宣传片，**App 界面全部来自 `prototype/index.html` 真实设计稿**（`tools/ui-shots.ts` 只读驱动原型实截 1170×2532 @3x，取景避开原型的 TBC 开发标记与调试 chips，内容不改动）：

| 文件 | 场景 | 真实界面 |
|---|---|---|
| `s01-meeting.mp4` | 会议实录 | Timeline「正在录音」状态块 + 设备弹层（录音中/电量/同步） |
| `s02-minutes.mp4` | 会后纪要 | 总结勾选模式 + 总结结果页（概览/信息点/行动项） |
| `s03-interview.mp4` | 双人访谈 | 详情「对话详情」说话人 1/2（推测）分段 + 图片归位 |
| `s04-offline.mp4` | 断网挑战 | 设置·本地语音引擎（Silero VAD / SenseVoice INT8 / CAM++ 已就绪）+ Timeline |
| `s05-raw.mp4` | 原始数据 | 详情「原始数据」播放器 + 按句高亮 |
| `s06-family.mp4` | 家的叮嘱 | 日报卡（按日分组）+ 总结结果页 |
| `s07-care.mp4` | 医嘱清单 | Timeline feed + 总结结果页 |
| `s08-class.mp4` | 课堂重点 | 信息点（默认展开 + 溯源 chips）+ 原始数据按句跳转 |
| `s09-podcast.mp4` | 播客回听 | 原始数据秒级定位 + 导出面板（完整文档/Markdown/PDF/图片/Word） |
| `s10-unbox.mp4` | 开箱上手 | 设备扫描（DYJ/点一机/语音AI键盘 按信号排序）+ 已连接弹层 + 正在录音出稿 |

构建：`tools/build-scenes.sh`（全部或单条 `./build-scenes.sh s03`）；界面截图可用 `bun ui-shots.ts` 单独重截（原型更新后建议重跑）。

## 成片

| 文件 | 人群 | 风格 | 时长 |
|---|---|---|---|
| `out/v1-office.mp4` | 25–40 职场人（会议重度） | 极简白 · 动态大字 | 21.5s |
| `out/v2-privacy.mp4` | 极客 / 隐私敏感 / 律师·医生·顾问 | 暗黑科技 · 本地转写流程可视化 | 22.5s |
| `out/v3-family.mp4` | 送礼给父母 / 家庭记录 | 米色暖插画 · 大字号 | 23s |
| `out/v4-student.mp4` | 大学生 / 记者 / 播客与自媒体 | 高饱和快剪 · 贴纸感 | 18.5s |
| `out/v5-launch.mp4` | 官网首屏 / 发布会 / 媒体 | 黑色 Keynote 产品 hero | 17.5s |

> 配乐为本仓库脚本参数化合成的原创小样（无版权风险）；正式投放前建议替换为授权曲目，人声旁白可后续叠加。

## 文件结构

```
marketing/videos/
├── brief.md            # 创意简报：调研结论、分镜、事实红线（含来源链接）
├── README.md           # 本文件
├── out/                # 成片 MP4（1080p30 H.264 + AAC）
└── tools/
    ├── renderer.html   # Canvas 1920×1080 逐帧渲染器（5 条风格片 + 10 条场景片模板）
    ├── capture.ts      # bun + headless Chrome CDP 确定性截帧 → PNG 序列
    ├── ui-shots.ts     # 只读驱动 prototype/index.html 实截真实设计稿 → tools/ui/*.png
    ├── music.ts        # bun 参数化配乐合成 → WAV
    ├── encode.swift    # AVAssetWriter：PNG 序列 + WAV → MP4（H.264/AAC）
    ├── build.sh        # 风格片一键构建（全部或单条：./build.sh v3）
    └── build-scenes.sh # 场景片一键构建（全部或单条：./build-scenes.sh s03）
```

## 复现

```bash
cd marketing/videos/tools
./build.sh          # 全部 5 条
./build.sh v2       # 只重做 v2
# 单步：
bun capture.ts v1 30            # 截帧 → /tmp/rc-promo/frames/v1/*.png
bun capture.ts v1 30 45         # 只渲第 45 帧（调试）
bun music.ts v1                 # 只合成 v1 配乐
swift encode.swift --frames /tmp/rc-promo/frames/v1 --fps 30 \
  --audio /tmp/rc-promo/music/v1.wav --out out/v1-office.mp4
```

环境要求：macOS + Google Chrome + [bun](https://bun.sh) + Xcode CLT（swift）。无 node/npm/ffmpeg 依赖。

## 事实红线（与 `docs/handoff/handoff-2026-11-11-live-slice-asr.md` 对齐）

- 宣传口径：蓝牙实时音频流、1 分钟切片本地转写（Silero VAD + SenseVoice-int8）、CAM++ 声纹推测说话人、云端仅文本润色/总结、原始录音可回听。
- 说话人一律标注「（推测）」，不冒认身份；不宣传音频上云、不宣传实名说话人识别。
