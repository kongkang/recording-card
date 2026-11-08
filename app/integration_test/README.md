# 全流程 integration_test 接线待办

本目录目前有接手契约，**没有伪造未冻结API的 Dart integration tests**。F 新增可运行测试在 `app/test/full_flow_fixture_test.dart`，独立流程/格式/窗口审计从本目录的相对路径为 `../../docs/test/qa/scripts`。旧20未删未改。

## 依赖与接口

当前无需新增包、平台改动。真正 runner 接入时由集成者统一添加：

```yaml
dev_dependencies:
  integration_test:
    sdk: flutter
```

A–E报告的**确切**签名是唯一接线来源。至少要冻结：AuthService OAuth/restore/signOut及其fake依赖；CardGateway方法/异常/资源释放；RecordingRepository与SettingsRepository内存fixture、SyncCoordinator任务事件；Transcription/Analysis输入输出；E AppStore/DeviceStore composition root及ExportService真实文件/分享适配。不要通过 subclass 猜 return type、用 `dynamic` 绕过编译或复制production seed回退。

可复用的现成测试helper：

```dart
import '../test/fixtures/full_flow_fixture.dart';
// fullFlowFixtureEvents() / fullFlowFixtureSummary()
// auditFixtureSources(summary, events, selectedIds: {...})
```

这些只依赖保留兼容的RecordEvent/SummaryCard旧constructor，ID为qa-orchid/qa-lantern，原始/清洗/来源分离。旧布局基线 e1…e6应另建**测试目录内**确定性fixture保持原Key；不要把qa记录塞进生产默认数据。

## 建议两个独立suite

**fake/offline 全流程**：使用测试composition root和临时目录、安全存储fake、授权HTTPfake、可控gateway/ASR/analysis/任务回执；不调用RealCardGateway、模型收费服务或native账号授权页。必须先检查默认production无配置失败，再显式fixture成功。Completer控制running/succeeded/failed/cancelled，不靠固定6秒advance就“成功”。输出生产ExportService真实五格式文件到临时目录并调用外部parser审计；share用测试adapter捕获文件列表，不向外部发送。

**iOS authorized device suite**：必须另获账号/硬件/网络授权，在用户选定Mac运行。测试case不可默认执行登录、BLE连接、上传/模型请求、Wi-Fi切网、OTA或BLE take；未配置资源明确blocked，不用skip标记通过。危险动作仅dry-run，精确授权后才设置allowDestructive/刷写授权。真机suite单独命名/手动选择，不纳入默认 `flutter test`。

## 最低case清单

1. clean install无安全会话→OAuth入口；非空密码拒绝。合法OAuthfake→profile→安全存储→重启恢复→退出清理。
2. production默认events空，无样例卡；显式两记录→详情raw/polished；来源合法且原文未覆盖。
3. source ABC→BCD→重复BCD→最终A/B/C/D去重且B/C source稳定；静音stage依据detector不越界；raw/polished/summary三视图一source；emotion/speaker/time不得伪造。
4. 手动选择仅A/B→analysis请求同时包含其polished与已有summary；无未选source/raw替代；失败/取消不能生成静态项目排期结果。
5. gateway unavailable/空文件列表/失败分离；AP下载长度/完整性/mark持久化；无授权BLE take与OTA调用不得触达fake native spy。
6. Wi-Fi/OTA native失败后等待超出旧timer仍不成功；OTA成功回执需重连验证版本（offline fake只能证明状态机）。
7. 生成完成→目录/Tabs/来源/反向引用/行动项完成→重开/重启；窄宽屏原布局与Key不变。
8. HTML/MD/PDF/PNG/DOCX实文件和内容；cancel share不外发；六Setting开关spy行为+重启持久化。

结果输出按 `docs/test/QA-EVIDENCE-CONTRACT.md` 的QA JSON，捕获实际被测值，不把fixture JSON直接作为runtime证据。测试通过与iOS build/真实设备通过严格分层；Mac命令和前置见 `docs/test/MAC-DEVICE-HANDOFF.md`。
