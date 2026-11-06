# 录音卡 · 设计确认原型

always-on 录音硬件（录音卡）伴侣 App 的设计确认仓库。当前阶段：**设计确认期**——`prototype/index.html` 是唯一交付物，设计打磨直接在它上面进行；定稿后才启动工程开发（技术栈未定）。

## 目录结构

```
recording-card/
├── AGENTS.md                # 本项目协作规则（给接手者/AI）
├── README.md
├── prototype/               # 设计确认稿
│   ├── index.html           # 主原型：单文件内联 CSS/JS，无构建、无外部资源
│   ├── verify.cjs           # 验收脚本（puppeteer-core + Chrome）
│   ├── package.json
│   └── screenshots/         # 验收截图（verify.cjs 自动刷新）
├── docs/
│   ├── SDK-CAPABILITY.md    # 上游 SDK 能力对照与数据边界
│   └── gen-evidence/        # 原型生成证据链：prompt/output 留存、核验结果、旧版脚本
└── archive/                 # 旧版原型与旧截图，仅追溯，不代表当前结构
```

## 预览

本地直接打开 `prototype/index.html` 即可，无需构建；或起静态服务：

```sh
cd prototype && python3 -m http.server 8767
```

## 验收

```sh
cd prototype && npm install && npm run verify
```

390×844 @2x，断言完整交互流程（展开/详情/原始数据/多选总结/筛选/开关/硬件弹层），并要求无网络请求、无 JS 异常；截图自动刷新到 `screenshots/`。当前状态：**pass**（2026-11-06）。

## 当前设计基线（2026-11-06 IA 改版）

- 底栏仅 **Timeline / Setting**；实时硬件状态由顶部胶囊统一管理（弹层）。
- Timeline：倒序事件，标题 + 两行摘要；首次点击原地展开，再次点击进入清洗对话详情；角落「原始」看口误、停顿与切片映射。
- 右上「总结」：当天片段多选、全选/取消、生成演示总结卡进时间轴；分类筛选不增加底栏。
- 总结结果含 Markdown 与可交互 HTML 两种视图，均为本地预置示例。
- Setting：导入偏好、演示开关、关于。

## 边界（重要）

纯本地演示：未接真实 BLE、ASR、声纹、LLM 或云端服务；说话人 A/B 为推测归整示例，不断言真实身份；总结生成不代表真实分析能力。SDK 实际可支撑范围见 `docs/SDK-CAPABILITY.md`。

## 后续路线

1. 设计打磨（当前）→ 2. 设计定稿 → 3. 工程开发。
