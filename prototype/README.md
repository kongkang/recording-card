# prototype/ · 录音卡交互原型与双版本开发规范

本目录是录音卡客户端的交互设计真源（单文件内联 HTML/CSS/JS，零构建、零外部网络依赖，可直接 `file://` 打开或通过本地静态 HTTP 服务预览）。

## 文件结构

| 文件 | 定位 | 存储隔离前缀 | 进度标记 |
| --- | --- | --- | --- |
| `current.html` | **当前版本**（与 `app/` 主干保持 1:1 真实能力映射） | `rc-route-cur-v1` / `rc-wifi-cur-v1` / `rc-vp-cur-v1` | 允许 `NC` / `NT`（零 `TBC`） |
| `index.html` | **目标版本**（当前版本全集 + 未来演进路线图） | `rc-route-v1` / `rc-wifi-v1` / `rc-vp-v1` | 同步 `NC` / `NT` + 未来 `TBC` |
| `releases/vX.Y.Z.html` | **发版快照**（对外发版时归档 `current.html`，只读） | `rc-*-snap-<slug>` | 按快照留存 |
| `snapshot-release.mjs` | 发版归档脚本（`node prototype/snapshot-release.mjs vX.Y.Z`） | — | — |
| `verify.cjs` | Playwright 双版本自动化验收脚本 | — | — |

## 进度标记体系：`NC` vs `NT` vs `TBC`

1. **`NC`（Need Confirm · 当前版本待确认立即开发）**
   - **含义**：属于本版本范围、已在设计稿完成交互更新，等待 owner 验收确认后**立即安排 `app/` 开发**的功能。
   - **展示**：在对应控件旁标注 `NC` 徽章（`.nc-badge`），并在顶栏提供 `NC·N` 胶囊（`[data-testid="nc-btn"]`）汇总清单，方便按条点跳核验。
   - **生命周期**：设计修改期间先更新 `prototype/current.html` 并同步 `prototype/index.html` → owner 在侧边栏确认设计 → 在 Flutter `app/` 开发与测试对齐 → 摘除 `NC` 徽章并从清单移除。**未确认前不提前动 `app/` 对应需求代码**。

2. **`NT`（Need Test · 已开发待继续完善设计与完成测试）**
   - **含义**：核心代码已开发落地，但仍需继续打磨交互细节设计，并完成真机 / 专项兼容性测试验证后方可摘标的功能。
   - **展示**：在对应设置入口、子页标题或清单旁标注紫色 `NT` 徽章（`.nt-badge`），并在顶栏提供 `NT·N` 胶囊（`[data-testid="nt-btn"]`）汇总待测项，支持一键直达对应演示状态。
   - **归属**：可同时存在于 `prototype/current.html` 与 `prototype/index.html`（真机专项测试全部通过后摘除 `NT`）。

3. **`TBC`（To Be Confirmed · 目标版未来规划）**
   - **含义**：面向未来迭代的演进设计，目前尚未排入当前版本开发。
   - **展示**：仅允许出现在 `prototype/index.html`（`.tbc-badge`），由顶栏 `目标版·M` 清单统一索引；`prototype/current.html` 严格保持 **0 个 `TBC`**。
   - **晋升流转**：仅当 owner 明确确认将某项 `TBC` 纳入当前版本时，才从 `index.html` 的 `TBC` 清单移除并同步合入 `current.html`（开发前标为 `NC`，开发完视测试完成情况决定去标或标 `NT`）。

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
