# Apple Watch × iPhone 双端联动 1:1 HTML 设计稿

本目录放置 **录音卡**（`com.reai.recordingcard`）与 **Apple Watch 客户端**（`watch/`）的交互设计真源页面，直接复用主端已确认的双版本原型而不再维护独立缩水版手机界面。

## 文件说明

- `watch/prototype/index.html`：双端联调宿主页
  - **左侧 iPhone 16 Pro 屏（`390×844`）**：通过同源 `<iframe>` 直接加载确认版主端设计稿（支持顶部切换 `[ 当前版（App 已实现） | 目标版·12 ]`，分别对应 `../../prototype/current.html` 与 `../../prototype/index.html`）；状态栏灵动岛与锁屏实况卡片 1:1 对齐 `RecordingCardLiveActivityWidget.swift` 与 `live_activity_service.dart`。
  - **右侧 Apple Watch**：可切换 Ultra 49 mm、Series 46 mm 与小尺寸 40 mm，提供「手表应用 / 表盘组件 / 息屏预览」三视图，1:1 对齐 `watch/WatchApp/WatchMainView.swift` 与 `watch/WatchWidgets/RecordingCardComplication.swift`；电量文案严格使用三档表达（`充电中 / 电量高 / 电量中 / 电量低`），不显示百分比或「已充满」。
- `watch/prototype/verify.mjs`：静态红线检查 + 基于本地 HTTP + 无头 Chrome 的双端联动 E2E 验收脚本（由 `.github/workflows/watch-prototype.yml` 自动运行）。

## 核心设计要点（2026-11-15 定稿对齐）

1. **watchOS 11 Infograph Modular 表盘组件（`#w-face`）**：
   - 进入「表盘组件」视图时隐藏应用顶栏 `#w-top-bar`，外圈呈现表盘刻度（`.wf-ticks`）。
   - 顶部左角标 `comp-corner`（圆环进度 + 状态）配右侧无边框状态指示 `comp-inline` 与大号数字时钟；中央矩形复杂功能 `comp-rectangular` 在录音态亮起珊瑚红强调并展示实时 10 柱声波与电量档位；底部三联圆形小表盘 `comp-circular` / 日历 / 电量环可点击直达开录与状态切换。
2. **手表端极简一屏界面（`#w-app` / `WatchMainView.swift`）**：
   - **顶部极简**：不展示 App 标题；左上同列展示手机连接状态与电量档位，右上保留 watchOS 系统时间。
   - **机身敲两下打重点**：移除会误触或挤压空间的屏幕打点按钮与底部 `GPS·心率` 标签；录音中直接快速双击/轻敲手表机身或表盘主区即可触发物理敲击打点并弹出 `已打点 N` 脉冲提示，主屏仅保留非按钮提示文案「轻敲两下机身打点」。
   - **纯平哑光停止滑块 + 紧贴底栏**：采用老式 iPhone 滑块式 `滑动停止录音` 防误触控件，滑钮保持纯平哑光正红 `#FF3B30`（无金属高光渐变）；息屏（AOD）态显示「先点亮屏幕 · 再滑动停止录音」，先点亮屏幕再滑动。滑轨在紧凑布局为 44 pt，宽松布局为 48 pt。队列栏背景贴屏幕底边，文字和触控留在安全区。滑轨正下方紧贴底部 60 秒单圈倒计时环（`单圈 XXs`）与分段同步入口（`待传 N 段 ›` / `已同步 N 段 ›`）。
3. **手机端 Setting 子页改版（`prototype/current.html` & `prototype/index.html`）**：
   - **第三方硬件联动（`exthw`）**：采用统一简洁开关行（`得到 Get 笔记录音卡 GSC10`、`Omi 随身录音器 Friend`），去除开发向 `SDK Crate` 说明文字与错行卡片。
   - **行为与健康信号（`health` · `NC·1`）**：顶部保留 `同步位置与健康信号` 总控开关（`仅存本机 · 随录音自动记录`），下方按时间倒序逐条展示真实采集到的活动态、心率/血氧/HRV/步频与位置记录明细。

## 预览与校验

```bash
# 1. 在仓库根目录启动静态服务
python3 -m http.server 18924 --bind 127.0.0.1

# 2. 打开双端联动页：
# http://127.0.0.1:18924/watch/prototype/index.html

# 3. 自动化验收
node prototype/verify.cjs
node watch/prototype/verify.mjs
```
