# 全流程 QA 接手（F，2026-11-08）

开发审批已生效，以 `DEVELOPMENT-CONTRACT.md` 为准；旧 AGENTS 中默认 seed/假会话规则已过时。本目录交付的是**可运行的 QA 工具、显式夹具和验收契约**，不是“新全流程已通过”。F 只编辑本 worktree 的测试/本目录/独立 QA 脚本，不编辑生产源码、prototype 或其他工作区。

## 当前证据等级

| 层次 | 本次事实 | 不代表 |
|---|---|---|
| 旧基线 | `ef02d84` 的原 20 项 Flutter tests 原样保留并实际通过，有 1 处既有 drag hit-test 警告 | OAuth/BLE/ASR/五格式导出/Wi-Fi/OTA 真链路通过 |
| 新夹具 | 8 项 Dart 模型/来源夹具测试通过；只使用已存在 RecordEvent/SummaryCard API | 新服务 API、总结模型准确性或生产来源校验已通过 |
| QA 工具 | 54 项 Python 正反例通过（含16项窗口/静音/三视图/手动输入/metadata）；运行两种 evidence fixture、五格式 parser specimens | 生产 ExportService 生成过这五份文件，或真实任务成功 |
| 安全审计 | source strict 在本分支基线返回 1，检出 7 BLOCKER、2 REVIEW、5 UNVERIFIED | 集成后仍有相同问题；必须对集成 SHA 重跑 |
| Mac/真机 | 仅有接手指南和安全默认的预检脚本；Linux 预检明确拒绝 | iOS 编译、签名、安装或任何真机链路已通过 |

每项验收分别填写 `implemented / automated_pass / device_pass / blocked`，**不要平均或把 fixture 通过升级为 device_pass**。全部自动结果需要记录被测 SHA、命令、环境与日志；来源 JSON 的 `evidence_kind` 不能随意从 fixture 改成 device。

## 立即可运行（无账号、无网络服务、无硬件）

在当前 worktree 根目录运行：

```bash
export PATH=/home/ubuntu/flutter/bin:$HOME/.cargo/bin:$PATH
python3 -m unittest discover -s docs/test/qa/scripts -p 'test_*.py' -v
python3 docs/test/qa/scripts/qa_audit.py baseline --root . \
  --inventory docs/test/qa/fixtures/baseline_inventory.json --require-legacy-hash
python3 docs/test/qa/scripts/qa_audit.py flow docs/test/qa/fixtures/flow_evidence.fixture.json
python3 docs/test/qa/scripts/qa_incremental.py docs/test/qa/fixtures/incremental_evidence.fixture.json
python3 docs/test/qa/scripts/qa_audit.py source --root . --strict
# source --strict 当前预期非零：必须展示发现，不忽略作绿色CI。
cd app
flutter pub get
flutter test test/full_flow_fixture_test.dart --reporter expanded
flutter test --reporter expanded
flutter analyze
```

本次 `flutter pub get` 获取的仅是基础 Flutter 测试依赖，不调用业务模型；Flutter 3.47.9 自动升级了6个基础依赖并在 analysis_options 添加 build/platform exclude，日志有明确迁移记录。完整28项Flutter tests和analyze已实际通过，但测试使用的是此自动迁移环境，而非原始lock。工具链由协调者安装，不重复安装；F 不提交 pubspec/lock/analysis_options（自动迁移文件留未提交交集成者处理）。审计工具的 `--output PATH` 是**顶层参数**，放子命令前，如 `qa_audit.py --output /tmp/source.json source --root . --strict`。未传 output 时只打印脱敏结果；源审计只读，不写源文件。

### 五格式独立 parser 样本

```bash
OUT=$(mktemp -d)
python3 docs/test/qa/scripts/generate_qa_specimens.py --output-dir "$OUT"
python3 docs/test/qa/scripts/qa_audit.py exports "$OUT/export_manifest.json"
```

样本是工具生成的 QA-only 文件，不经过生产导出服务。生产导出准备好后，由 E/集成测试输出真实文件，并提供同形 manifest：`schema_version:1`、真实 `evidence_kind`、`required_text:[标题片段,正文片段,来源ID或来源标签+时间]`、`formats:{html,markdown,pdf,png,docx}` 的文件路径。至少用两组不同输入，包括本夹具的中文、特殊字符和合法来源；禁止单靠扩展名、toast 或文件数量判断导出成功。

工具检查 Markdown 标题/UTF-8、完整 HTML 结构及禁活动脚本、PDF 由 Poppler 实际解析、PNG 签名/CRC/压缩数据/尺寸、DOCX ZIP CRC + OOXML content-type/relationship/document + 内容；四种文本格式均匹配 required_text。**PNG 图文完整性/长文分页/截断必须视觉核验，系统分享面板必须在 iOS 验；本工具不能代替这两项。** PDF 中文需实际字体嵌入/解析检查，不用 ASCII parser 样本冒充中文导出。

### ASR 文件只读预检

```bash
python3 docs/test/qa/scripts/qa_audit.py models \
  docs/test/qa/fixtures/sensevoice_expected.reference.json --base /approved/model/directory
```

这是校验指定本地文件的大小和 SHA-256，不下载、不调用推理。参考清单来自授权只读参考 App；D 必须确认具体采用模型、权重来源、许可、版本和最终清单，不能把参考 checksum 当成本工程已部署模型。无文件应失败，不创建“模型已配置”的假成功。

## 给集成者的明确接线信息

新增 Dart public helpers 位于 `app/test/fixtures/full_flow_fixture.dart`，只能从 tests/integration_test 引用：

```dart
List<RecordEvent> fullFlowFixtureEvents();
SummaryCard fullFlowFixtureSummary();
List<String> auditFixtureSources(
  SummaryCard summary,
  List<RecordEvent> events, {
  required Set<String> selectedIds,
});
```

前两者返回新列表/新总结对象，ID 为 `qa-orchid` / `qa-lantern`，来源总结仅选 `qa-orchid`。原始语气词与清洗文本分开保留，说话人明确“推测”。oracle 返回违规字符串列表，空列表表示只通过此 oracle；当前公开模型 `SourceRef.range` 为 HH:mm，本 helper 不臆造跨午夜/日期偏移。新生产时间字段请另导出毫秒证据交给 `flow` 检查，不能只核对展示时间。

**没有新增/猜测生产 API**；只有 `RecordEvent` 原构造、`TurnLine`、`SummaryCard`、`toJson/fromJson`、`SourceRef/InfoPoint/MapBranch` 被实际调用。`app/integration_test/README.md` 指定接口冻结后的适配步骤，尚未建立依赖未定义 API 的不能编译测试。

Python public functions 为 `audit_flow(data)`、`audit_exports(manifest, base)`、`audit_models(manifest, base)`、`audit_source(root)`、`audit_baseline(root, inventory, require_legacy_hash=False)`；违规抛 `AuditError`，source 返回 finding list，CLI 用 exit 0/1；Mac 不支持平台/前置不齐用 exit 2。`generate_qa_specimens.write_specimens(directory)` 只生成 parser 样本。
补充 `qa_incremental.audit_incremental(data)` 与同名脚本CLI，校验ABC→BCD→重复BCD幂等、raw摘要不变/无云污染、静音stage、三视图同源、手动polished+existing summary输入和metadata出处；仍只验证QA证据契约，不调用新生产API。

F 没有平台变更。依赖：已有 `flutter_test`、Python 3 标准库、PDF 内容验证用 `pdftotext`（Linux 已有；Mac 可用 Poppler），Mac 脚本要已有 Flutter/Rust/Xcode/CocoaPods；**无需新增 Dart 包**。后续真正 integration_test runner 需集成者统一加 `integration_test: {sdk: flutter}`，F 当前未引用它。

## 旧 20 回归迁移纪律

`qa/fixtures/baseline_inventory.json` 保存 4 个旧测试文件的 SHA 和 20 个名称，及两份 prototype 的只读 SHA。F 未改任何旧文件。集成者改夹具时先保持名称/交互/布局/Key 断言，不能通过删测试、skip 全组或放宽尺寸掩盖回归。

1. `auth_test.dart` 的“非空凭据建立本地会话/成功进入外壳”必须改为**显式 OAuth fake 注入**的成功路径，同时增加默认 AuthService 非空账号密码仍拒绝、state 不符/取消/profile失败/安全存储为空恢复失败的负例。默认生产 auth 不能为了旧测试而成功。
2. `verify_narrow_test.dart` / `verify_wide_test.dart` 的 `AppStore()` 改为 E 最终 composition seam 的显式记录、内存仓库、可控 AnalysisService fake。固定 e1…e6/文案可在测试目录独立夹具保留以复用旧 Key；不要求生产空库拥有这些记录。F 的 qa-orchid 夹具是另一路非样例输入语义验收，不直接替换旧卡片 ID。
3. 原固定 6 秒、Wi-Fi 1.2 秒、OTA 6 秒断言只适用于注入的可控 fake；阶段应由 Completer/真实任务事件驱动。旧 ETA 数值断言迁移为阶段/不确定进度语义，**仍保留状态区域、吸顶/目录/锁定/路由的布局断言**；这属于已批准的真实进度语义，不是缩减布局。
4. `verify_device_test.dart` 使用 B/E 已冻结的 test fake gateway + fake任务回执；失败/取消/超时再 advance 时间绝不能出现成功。不要让测试 fixture 创建 RealCardGateway 或自动选默认 Mock。
5. 原导出 toast 断言只能证明 UI 反馈；追加真实五格式 file assertions 和 iOS share sheet 验收后才能将导出功能算通过。六开关颜色变化只能证明 UI，另加每个业务效果与重启持久化断言。
6. 移植后运行 baseline 审计**不加** `--require-legacy-hash`，允许合理夹具修改但仍检查名称；此脚本不分析断言质量，集成者必须人工 diff 审查。prototype hash 检查始终严格。保留旧 test 数量并不能单独证明 62 项完整映射。

详见 [功能矩阵](FULL-FLOW-ACCEPTANCE-MATRIX.md)、[Mac 接手](MAC-DEVICE-HANDOFF.md) 和 [证据契约](QA-EVIDENCE-CONTRACT.md)。
