# 录音卡 · 5 条宣传视频创意简报（2026-11-12）

## 0. 产出物

| 文件 | 版式 | 时长 | 人群 | 风格 |
|---|---|---|---|---|
| `out/v1-office.mp4` | 16:9 1080p | ~21.5s | 25–40 职场人（会议重度） | 极简白 · 动态大字（Kinetic Typography） |
| `out/v2-privacy.mp4` | 16:9 1080p | ~22.5s | 极客 / 隐私敏感 / 律师·医生·顾问 | 暗黑科技 · 流程动效（Dark Tech） |
| `out/v3-family.mp4` | 16:9 1080p | ~23s | 送礼给父母 / 家庭记录 | 温暖插画 · 大字号（Warm Illustration） |
| `out/v4-student.mp4` | 16:9 1080p | ~18.5s | 大学生 / 记者 / 播客与自媒体 | 高饱和快剪 · 贴纸感（Fast Cuts） |
| `out/v5-launch.mp4` | 16:9 1080p | ~17.5s | 官网首屏 / 发布会 / 媒体 | 发布会大字报（Keynote Product Hero，紧凑节奏） |

## 1. 调研结论（方法论依据）

- **黄金 3 秒**：约 72–75% 用户 3 秒内决定去留；钩子要同时打「视觉 + 文案 + 字幕」三通道，用冲突/反差开场，绝不用 logo 开场。
- **结构**：hook → problem → solution/demo → proof → CTA 五段式；CTA 只给一个动作。
- **完播率**：15–40 秒最稳；3/5/10 秒设留存节点（反转、悬念）；节奏短平快、转场卡点。
- **风格 × 人群匹配**：动态大字适合短促有力、文案是主角的片子（<30s）；暗黑极简 motion graphics 适合 SaaS/开发者；温暖 2D 插画适合大众与情感叙事；快剪高饱和适合年轻群体；产品 hero + spec 大字适合发布会与官网。

来源：
- [Vidico · 12 Best Product Demo Video Examples（五段结构）](https://vidico.com/news/best-product-demo-video-examples)
- [NovoAds · Ad Hooks: 前 3 秒 12 种公式](https://novoads.ai/en/blog/how-to-make-ad-hooks)
- [CapCut · Short-Form Video Hooks](https://www.capcut.com/create/short-form-video-hooks-first-3-second-patterns)
- [Opus · TikTok Hook Formulas](https://www.opus.pro/blog/tiktok-hook-formulas)
- [腾讯云开发者 · 短视频完播率数据](https://cloud.tencent.com/developer/article/2579413)
- [知乎 · 完播率 30% 与 15–40 秒时长](https://zhuanlan.zhihu.com/p/563947416)
- [Yans Media · Explainer 视频类型](https://www.yansmedia.com/blog/types-of-explainer-videos)
- [Animatron · 按人群选动画风格](https://www.animatron.com/blog/how-to-choose-the-best-animation-style-for-your-explainer-videos)
- [Moonb · Explainer Video Types](https://www.moonb.io/blog/explainer-video-types)
- [人人都是产品经理 · 黄金 6S 原则](https://www.woshipm.com/operate/4123488.html)

## 2. 事实红线（宣传不得超出产品真实能力）

依据 `docs/handoff/handoff-2026-11-11-live-slice-asr.md`（真机 iPhone 13 mini 实测基线，258/258 测试通过）：

- ✅ 可宣传：BLE **实时音频流**录音、每满 1 分钟自动切片、**本机** Silero VAD + SenseVoice-int8 转写、CAM++ 声纹推测说话人、自动写入 Timeline、云端只做文本润色与总结、原始数据可回听（按句跳转）、导出。
- ⚠️ 必须带限定词：说话人只能写「说话人 1（推测）」，不断言真实身份。
- ❌ 不得宣传：说话人实名识别、云端实时转写、音频上传云端、无限实时（BLE 带宽有限）。

## 3. 分镜脚本

### V1 职场效率（极简白 · 动态大字）
| 时间 | 画面 | 文案 |
|---|---|---|
| 0–2.6s | 大字弹入，红线划过 | 开了 2 小时会，纪要还没写。 |
| 2.6–5.5s | 便签乱飞挤满屏 | 谁负责？/ 下周几？/ 预算多少？ |
| 5.5–8s | 硬件卡滑入桌面，REC 亮起 | 一放，就开录。 |
| 8–14s | 手机 Timeline 卡片逐条弹入（说话人 1（推测）…） | 边录边出稿 · 1 分钟一段 |
| 14–17.5s | 总结卡升起：概览/信息点/行动项，行动项逐条打勾 | 一键生成纪要 |
| 17.5–20s | 三个绿勾 chip | 1 分钟出稿 · 本地转写 · 云端润色 |
| 20–21.5s | 黑底 end card | 录音卡 —— 开完会，纪要已就绪。 |

### V2 隐私极客（暗黑科技）
| 时间 | 画面 | 文案 |
|---|---|---|
| 0–2.5s | 红色波形跳动 | 你的录音，正在被传到哪里？ |
| 2.5–7s | 普通方案：音频文件飞向云端（红 ×） | 它们把你的声音传上云。 |
| 7–15s | 录音卡方案：设备框内 波形→VAD→SenseVoice 打字机→声纹圈；只有文字细线到云 | 音频锁在本机 · 转写不出门 |
| 15–19.5s | terminal 滚动 | audio: local ✓ / upload: text only ✓ |
| 19.5–22.5s | end card | 录音卡 · 声音不出门。 |

### V3 温暖家庭（米色插画）
| 时间 | 画面 | 文案 |
|---|---|---|
| 0–2.8s | 米色底大字 + 3 个问号气泡 | 妈妈电话里说的 3 件事，你还记得几件？ |
| 2.8–6.5s | 便签：空腹吃降压药 / 周三复查 / 少盐，被问号包围 | 病房里的一串叮嘱，记不住太正常。 |
| 6.5–9s | 硬件卡软阴影登场 | 一放，就开始记。 |
| 9–16s | 大字号 Timeline + 「今日叮嘱」清单逐条打勾 + 相册小图 | 转成大字，整理成清单 |
| 16–20.5s | 特点 chip | 字够大 · 自动整理 · 一键回听 |
| 20.5–23s | 暖橙 end card | 录音卡 · 把每一句叮嘱，都好好收着。 |

### V4 学生记者（高饱和快剪）
| 时间 | 画面 | 文案 |
|---|---|---|
| 0–2s | 三连大字砸屏 | 3 小时的课！重点在哪！？ |
| 2–5s | 硬件卡弹出 + 旋转贴纸 | 只管录。 |
| 5–11s | 时间轴快速滚动 → 搜索「考试范围」→ 黄色荧光笔扫过 | 录完自动成稿，一搜就到。 |
| 11–14.5s | 行动项清单快速打勾 | 待办自动拎出来。 |
| 14.5–16.5s | 导出按键 → 文档飞出 | 一键导出 Markdown。 |
| 16.5–18.5s | end card | 录音卡 · 只管录，重点我来找。 |

### V5 发布会品牌（黑色 Keynote · 17.5s 紧凑版）
| 时间 | 画面 | 文案 |
|---|---|---|
| 0–2.2s | 黑场逐词点亮（0.06s/字） | 一张卡片，记住你说过的每一句话。 |
| 2.2–5.6s | 产品 hero 弹入 + 光环 + 高光扫过 | （无字，纯视觉） |
| 5.6–10.8s | hero 左移，四角 spec 深色 chip 标注每 1.1s 依次点亮 | 蓝牙实时音频流 / 1 分钟切片·本地转写 / 声纹识别·说话人（推测） / 智能总结·日报 |
| 10.8–14.6s | hero 缩至左侧，三屏 UI 0.22s 间隔弹入 | 录下，就已成稿。 |
| 14.6–17.5s | 黑场顿 0.3s → 品牌 punch 进场 + 光环 | 录音卡 —— 录下，即记住。 |

## 4. 技术管线（无 node/ffmpeg 环境下的做法）

1. `tools/renderer.html`：Canvas 1920×1080，`window.render(videoId, t)` 纯函数逐帧绘制（确定性动画，含硬件卡/手机 UI/波形/打字机等 mock）。
2. `tools/capture.ts`（bun）：启动 headless Chrome，走 CDP（WebSocket）逐帧 `render()` + `Page.captureScreenshot` → PNG 序列。
3. `tools/music.ts`（bun）：参数化合成每条片子的配乐（pad/pluck/kick/hat），输出 44.1kHz WAV。
4. 合成：优先静态 ffmpeg（x264 + AAC mux）；不可用则 `tools/encode.swift`（AVAssetWriter）+ `afconvert`。
5. 复现：
   ```bash
   bun tools/capture.ts v1           # 渲染 PNG 帧
   bun tools/music.ts                # 生成配乐 WAV
   tools/build.sh                    # 合成 MP4
   ```
