# prototype/ · 录音卡交互原型与双版本开发规范

本目录是录音卡客户端的交互设计真源（单文件内联 HTML/CSS/JS，零构建、零外部网络依赖，可直接 `file://` 打开或通过本地静态 HTTP 服务预览）。

## 文件结构

| 文件 | 定位 | 存储隔离前缀 | 进度标记 |
| --- | --- | --- | --- |
| `current.html` | **当前版本**（与 `app/` 主干保持 1:1 真实能力映射） | `rc-route-cur-v1` / `rc-wifi-cur-v1` / `rc-vp-cur-v1` | 允许 `NC`（零 `TBC`） |
| `index.html` | **目标版本**（当前版本全集 + 未来演进路线图） | `rc-route-v1` / `rc-wifi-v1` / `rc-vp-v1` | 同步 `NC` + 未来 `TBC` |
| `releases/vX.Y.Z.html` | **发版快照**（对外发版时归档 `current.html`，只读） | `rc-*-snap-<slug>` | 按快照留存 |
| `snapshot-release.mjs` | 发版归档脚本（`node prototype/snapshot-release.mjs vX.Y.Z`） | — | — |
| `verify.cjs` | Playwright 双版本自动化验收脚本 | — | — |

## 进度标记体系：`NC` / `TBC` / `F`（2026-11-17）

> 完整工作流见仓库根 `AGENTS.md`。**日常设计入口**改为 `../watch/prototype/index.html`（手机 iframe + Watch 同屏，顶栏切当前/目标）。本目录 `current.html`/`index.html` 仅内部真源；手机壳内不再放版本切换；Watch 同用 `NC`/`TBC`/`F`。

1. **`NC`（Need Confirm / Need to Complete · 当前版本待确认立即开发）**
   - **含义**：属于本版本范围、已在设计稿完成交互更新，等待 owner 验收确认后**立即安排真机开发**的功能。
   - **展示**：控件旁 `NC` 徽章（`.nc-badge`）+ 顶栏 `NC·N` 清单（`[data-testid="nc-btn"]`）。
   - **生命周期**：改 `current.html` 并同步目标版 → owner 确认 → `app/`/`watch/` 开发对齐 → 摘除 `NC`。**未确认前不提前动对应需求代码**。

2. **`TBC`（To Be Continued · 目标版未来规划）**
   - **含义**：目标版相对当前版的未来差异；尚未排入当前版开发。
   - **展示**：仅目标版（`.tbc-badge`）+ 顶栏 `目标版·M`；`current.html` 严格 **0 个 `TBC`**。
   - **晋升**：owner 确认纳入当前版 → 移出 `TBC` → 合入当前版标 `NC` → 开发完去标。

3. **`F`（Fake · 真实 App 不可用 / mock / 假功能）**
   - 相对真机重评（旧评估作废）：不能用、错误、或仅 mock 的能力必须标 `F`。
   - **橙 `F`**：入口可点但内部有 fake 子集 → 二级页对应处标 **红 `F`**。
   - **红 `F`**：整项/整块都是 fake，入口直接红标。
   - 设计阶段消掉或改成真需求后再转 `NC`；禁止把仍标 `F` 的当已交付。

## 协作约束

- **修改先改原型再推进确认**：常规设计修改先更新 `current.html` 与 `index.html` 对应位置并提交 PR 合并，待 owner 确认后进入 `app/` 开发；若明确仅调整未来规划，只修改 `index.html` 与 `TBC` 清单。
- **双页同源同步**：任何进入 `current.html` 的能力改动都必须同步合入 `index.html`，确保 `目标版本 ⊇ 当前版本` 始终成立。
- **本地预览与验收**：
  ```bash
  # 在 prototype/ 目录启动本地静态服务后访问 current.html / index.html
  python3 -m http.server 8765 --bind 127.0.0.1 -d prototype

  # 运行自动化双版本校验
  node prototype/verify.cjs
  ```
