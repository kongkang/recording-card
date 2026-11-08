# 录音卡 App 服务层架构（2026-11-08）

> 目标：把「录音 → 本地转写 → 增量润色 → 事件切段 → 手动总结 → 导出」整条链路
> 拆成可注入、可单测的接缝；真实外部依赖（BLE/ASR/云端）不在测试里伪装成功。

## 数据流

```
录音卡（BLE/AP）
   │  AudioSliceSource（接口；真实实现待 card_bridge）
   ▼
AudioSliceRepository ── AudioBlobStore（音频本体）
   │
   ▼
TranscriptionPipeline（Setting: 自动转录 / 清洗 / 说话人）
   │  TranscriptionService（真实实现待 sherpa_onnx + 模型包）
   ▼
IncrementalRefineCoordinator（窗口 A / A+B / A+B+C / B+C+D）
   │  SegmentRefiner ── CloudSegmentRefiner（模型网关）
   ▼
StagedSummaryCoordinator（长静音切事件）
   │  EventSummarizer ── CloudEventSummarizer（模型网关）
   ▼
RecordingRepository（KvStore 元数据 + 本地音频）
   │  RecordingViewAdapter → RecordEvent（现有 Timeline/详情 UI）
   ▼
手动总结：AppStore → SummaryArticleService → SummaryArticle → SummaryCard
   ▼
ExportService（Markdown / 完整文档 / PDF / PNG / DOCX + 系统分享）
```

## 模块与接缝

| 模块 | 文件 | 真实实现 | 测试替身 |
|---|---|---|---|
| 键值存储 | `lib/core/storage/kv_store.dart` | SharedPreferences | `MemoryKvStore` |
| 安全存储 | `lib/services/oauth/secure_store.dart` | Keychain/Keystore | `MemorySecureStore` |
| OAuth | `lib/services/oauth/*` | PKCE + 系统浏览器 + token 刷新 | MockClient / FakeLauncher |
| 模型网关 | `lib/services/model_gateway/*` | `/models`、`/chat/completions` | MockClient |
| 增量润色 | `lib/services/analysis/incremental_refine.dart` | 云端窗口润色 | FakeRefiner |
| 阶段总结 | `lib/services/analysis/staged_summary.dart` | 云端事件总结 | FakeSummarizer |
| 实时管线 | `lib/services/analysis/live_analysis_pipeline.dart` | 组合上述两段 | 同上 |
| 录音仓库/同步 | `lib/services/recordings/*` | KvStore + CardFileGateway | MemoryKvStore/FakeGateway |
| 转写 | `lib/services/transcription/*` | 待 sherpa_onnx 适配 | FakeTranscriptionService |
| 音频切片/状态 | `lib/services/audio/*` | 待 card_bridge 增量拉取 | Memory blob/KvStore |
| 录音→UI 适配 | `lib/services/recordings/recording_view_adapter.dart` | 现有 `RecordEvent` 模型 | 纯函数测试 |
| 手动总结文章 | `lib/services/analysis/summary_article.dart` | 模型网关 | FakeSummaryArticleService |
| 导出 | `lib/services/export_service.dart` | 文件字节 + share_plus | FakeSharer |

## 组合根

- `main.dart`：读取 `RC_OAUTH_*` / `RC_MODEL_GATEWAY_BASE_URL` / `RC_TEXT_MODEL`；
  配置齐全才启用真实 OAuth / 云端总结，否则保留本地会话/本地生成路径。
- `AppStore`：注入 `RecordingRepository` 后 Timeline 使用真实录音；
  注入 `SummaryArticleService` 后手动总结走云端，失败进入 `SummaryCard.error` 并可重试。
- `DeviceStore`：`CardGateway` 可注入；无桥/无硬件回退预置值，`connectionText`
  在桥可用但未连接时显示「未连接」。

## 外部阻塞（不伪装为已通过）

1. `card_bridge` 尚未链入 iOS/Android：无 Rust 工具链、无 `.a`/`.so`、
   pbxproj 无链接、Android 无 native 库；运行时回退 `MockCardGateway`。
2. `AudioSliceSource` / `CardFileGateway` 真实 BLE 增量拉取/文件取回未实现。
3. 本地 ASR：未加入 `sherpa_onnx`、未打包 SenseVoice 模型；`TranscriptionService`
   仅有接口与 Fake。
4. 云端 OAuth/模型网关需要真实 client 注册、redirect allowlist、scope、模型 ID；
   未提供时 App 不发起业务请求。
5. Wi-Fi 密码仍随 `DeviceStore` 存普通 SharedPreferences；接真实配网前应迁移
   Keychain/Keystore 并做迁移兼容。
6. 应用图标、隐私政策、账号注销、商店素材、release 签名仍未完成。
