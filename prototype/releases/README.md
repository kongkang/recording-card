# 发版设计快照（Release Snapshots）

本目录按对外发版节点（推送 TestFlight / 正式版 Git Tag `vX.Y.Z`）归档当时的 `prototype/current.html`，忠实记录每一次发版时 App 已落地的真实功能与界面形态。

## 生成快照

在对外发版打 Tag 时运行：

```bash
node prototype/snapshot-release.mjs v1.0.0
```

脚本会自动完成：
1. 将当前 `prototype/current.html` 归档为只读单文件 `prototype/releases/v1.0.0.html`（隔离存储键前缀，并将顶栏跳转路径修正为 `../current.html` 与 `../index.html`）；
2. 将该版本登记进 `prototype/current.html` 与 `prototype/index.html` 的 `RELEASE_SNAPSHOTS` 列表，使顶栏分段胶囊右侧自动展示 `▾` 历史快照下拉切换入口。

> 归档后的历史快照文件为**只读记录**，后续迭代请修改 `prototype/current.html` 或 `prototype/index.html`。
