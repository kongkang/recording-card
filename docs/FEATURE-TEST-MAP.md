# 功能 → 测试映射 / 交付状态（2026-11-08）

状态口径：**代码已实现 / 自动测试通过 / 真实链路通过 / 外部阻塞** 分开报告。
“自动测试通过”不等于真实硬件/云端验证通过。括号数字为测试文件内 test 声明数；
`flutter test` 实际执行 **170 个用例**（suite loading 事件不计入）。

| 功能组 | 代码位置 | 自动测试 | 状态 |
|---|---|---|---|
| OAuth2 PKCE / token 安全存储 / 401 刷新 | `lib/services/oauth/*` | `test/oauth_test.dart`（12） | 代码+自动测试通过；真实后端未验 |
| OAuth 登录编排（state/回调/换票/profile） | `lib/services/oauth/oauth_login_coordinator.dart` | `test/oauth_login_test.dart`（5）、`test/oauth_login_widget_test.dart`（3） | 代码+自动测试通过；真实 client 注册未提供 |
| 本地登录门 / 会话持久化 | `lib/services/auth_service.dart`、`lib/pages/login_page.dart` | `test/auth_test.dart`（4）、`test/persistence_test.dart`（12） | 自动测试通过 |
| 模型网关 `/models`、`/chat/completions` | `lib/services/model_gateway/*`、`lib/core/config/model_gateway_config.dart` | `test/model_gateway_test.dart`（4）、`test/model_gateway_config_test.dart`（3） | 代码+自动测试通过；真实网关未验 |
| 增量滑动窗口润色 A/A+B/A+B+C/B+C+D | `lib/services/analysis/incremental_refine.dart` | `test/incremental_refine_test.dart`（8） | 代码+自动测试通过；真实模型未验 |
| 长静音切段 + 事件总结 | `lib/services/analysis/staged_summary.dart` | `test/staged_summary_test.dart`（7） | 代码+自动测试通过；真实模型未验 |
| 实时分析管线（润色→切段） | `lib/services/analysis/live_analysis_pipeline.dart` | `test/live_analysis_pipeline_test.dart`（3） | 代码+自动测试通过 |
| 手动总结文章（选中分段→结构化总结） | `lib/services/analysis/summary_article.dart`、`AppStore` | `test/summary_article_test.dart`（9）、`test/summary_generation_test.dart`（2） | 代码+自动测试通过；真实模型/配置未验 |
| 录音仓库（元数据持久化/排序/容错） | `lib/services/recordings/recording_repository.dart` | `test/recordings_test.dart`（18）、`test/app_store_repository_test.dart`（2） | 自动测试通过 |
| 录音文件同步（去重/单文件失败/仅 Wi-Fi） | `lib/services/recordings/sync_coordinator.dart` | `test/recordings_test.dart` | 代码+自动测试通过；真实 `CardFileGateway` 未接 |
| 转写管线 + 设置开关生效 | `lib/services/transcription/*` | `test/transcription_test.dart`（6） | 代码+自动测试通过；真实 ASR 未接 |
| 音频切片仓库 + 录音状态机 | `lib/services/audio/*` | `test/audio_slice_test.dart`（26） | 代码+自动测试通过；真实 BLE 拉取未接 |
| 录音状态块（Timeline 顶部，不可点击） | `lib/widgets/recording_status_block.dart`、`lib/pages/timeline_page.dart` | `test/recording_status_block_test.dart`（2） | 自动测试通过 |
| 录音→Timeline/详情适配 | `lib/services/recordings/recording_view_adapter.dart`、`AppStore` | `test/view_adapter_test.dart`（9）、`test/app_store_repository_test.dart` | 自动测试通过 |
| 导出 5 格式 + 系统分享 | `lib/services/export_service.dart` | `test/export_service_test.dart`（6）、`test/verify_narrow_test.dart` | 代码+自动测试通过；真机分享未验 |
| 设计基线交互（窄屏/宽屏/路由/总结/状态页） | `lib/pages/*`、`lib/core/store/*` | `test/verify_*_test.dart`（20） | 自动测试通过（55 项 check 映射） |
| 设备网关（scan/connect/status/自动重连） | `lib/core/device/card_gateway.dart`、`lib/core/store/device_store.dart` | `test/device_gateway_test.dart`（8） | 代码+自动测试通过；桥未链入，真机仍回退 Mock |
| 本地音频播放/波形 | 未实现 | — | 外部阻塞/未排期 |

## 外部阻塞清单

1. **Rust/BLE 构建链**：本机无 `cargo/rustc`；`card_bridge` 未链入 iOS
   （pbxproj 无引用、无 `.a`），Android 无 `.so`；`AudioSliceSource` /
   `CardFileGateway` 真实实现未接。
2. **本地 ASR**：未引入 `sherpa_onnx`，未打包 SenseVoice/Fun-ASR 模型；
   `TranscriptionService` 只有接口与 Fake。
3. **真实 OAuth/模型网关**：需要自有 client 注册、redirect allowlist、scope、
   模型 ID；未配置时 App 保持本地会话/本地生成，不发业务请求。
4. **Wi-Fi 密码安全存储**：当前随 `DeviceStore` 存 SharedPreferences；
   接真实配网前迁移 Keychain/Keystore。
5. **发布工程**：默认 Flutter 图标、隐私政策/账号注销、商店素材、
   Android release 签名、真机回归未完成。
