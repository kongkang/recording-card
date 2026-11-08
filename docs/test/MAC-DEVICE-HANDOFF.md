# Mac / iPhone 真机接手模板

**当前 Linux 沙盒没有 iOS 编译/签名/安装/真机成功证据。** 本文是接手步骤，未执行任何实际账号登录、付费模型、BLE连接、Wi-Fi切换、设备取回或刷写。请只在用户明确选定且授权的在线Mac操作，不自动换到其离线电脑。

## 0. 开始前记录

| 项目 | 待操作者填写 |
|---|---|
| 被测集成commit / branch（不合master） | 未填写 |
| Mac机型/macOS/Xcode/Flutter/Rust版本 | 未填写 |
| iPhone型号/iOS/开发信任/Developer Mode/签名Team | 未填写，不记录账号凭据 |
| 测试卡ID（日志用代号）/主控与Wi-Fi实际版本 | 未填写 |
| 对应获准动作/授权时间/测试文件可处置范围 | 当前只允许代码/离线测试；真实危险操作禁止 |
| 五格式样本与脱敏日志目录 | 使用受保护本地目录，不上传公开文件 |

## 1. 必须确认的外部前置

- **OAuth**：获准复用的public client ID、issuer/baseURL、authorization/token/profile端点、精确redirect scheme/URI、scope、业务host allowlist、允许安装录音卡的server redirect注册。A报告最终 `--dart-define` 名称；本指南不猜它。先确认与参考App同scheme同时安装不会争抢callback。Keychain独立命名空间，不复制任何现存token或client secret。测试账号与登录操作须另获批准；本任务授权不是实际登录授权。
- **模型网关**：实际 `/models` 和 `/chat/completions` 等端点以A报告为准、允许文本model IDs、scope/权限、有限调用额度、非敏感文本/音频。没有授权/额度不执行；不能把GitHub权限当作OAuth权限。
- **ASR**：D确认SenseVoice-int8/tokens清单、可信权重来源、许可、sha256/size、App可访问文件路径或受控下载配置。参考模型 `model.int8.onnx` 239233841 bytes + `tokens.txt` 315894 bytes，具体digest见 `qa/fixtures/sensevoice_expected.reference.json`；仅是参考元数据，仓库不含权重。sherpa_onnx参考1.13.3但最终版本/移动framework由集成者统一；长音频如依赖VAD另需对应模型。无权重/native库是明确阻塞，不空文成功。不整包复制键盘native/fllama。
- **硬件**：指定录音卡/可用固件版本、权限、只读合法测试录音、连接槽空闲（停止Light/Driver对该测试卡的占用，但不强改用户绑定）。BLE拒权/断连需要明确提示。AP/iOS本地网络访问与Wi-Fi SD占用互斥待B方案确认。
- **同步服务**：C明确上传URL、方法、认证、body/content-type、成功响应与重复幂等语义；未配置不测试真实上传，也不把只下载本地算“同步上传成功”。
- **Wi-Fi/OTA**：获批测试2.4GHz网络与受保护密码输入；不得把密码写define/报告/Git。OTA需要真实清单、目标硬件身份/板型、包校验、主控/Wi-Fi目标版本、SDK要求的先后顺序和单独精确刷写授权；当前无授权，只做contract/dry-run。**BLE take可能删源，默认allowDestructive=false，不试探性调用。**

## 2. 本地构建预检（不探测硬件）

工具链必须已经准备好，不由QA重复安装。项目路径任选本次集成副本，先记录HEAD：

```bash
cd /path/to/approved/recording-card
export PATH=/path/to/flutter/bin:$HOME/.cargo/bin:$PATH
git rev-parse HEAD
git status --short
bash docs/test/qa/scripts/mac_preflight.sh --check-only
python3 docs/test/qa/scripts/qa_audit.py baseline --root . \
  --inventory docs/test/qa/fixtures/baseline_inventory.json
python3 -m unittest discover -s docs/test/qa/scripts -p 'test_*.py' -v
```

脚本在Linux返回2明确blocked；Mac只查工具/SDK/Rust targets，不运行 `flutter devices`、BLE、登录或刷写。device/simulator不同target需分开报告；预检脚本要求 `aarch64-apple-ios` 与 `aarch64-apple-ios-sim` 两target，不满足时按本次目标准备，不把缺sim target当作device功能失败。

**native链接先按B的确切报告执行，不猜脚本路径：**确认staticlib由授权只读SDK版本构建，iOS target架构一致，SDK系统framework与库依赖具备，Runner链接强制保留native-symbols。必核查B报告完整C ABI，尤其原`card_bridge_free_string`的真实释放与Dart finally/late-event处理；不能只看到lib文件存在就算通过。可在Mac用 `nm -g` 检查B列出的每一个符号，再看Runner可执行文件最终仍保留。`card_bridge_version`静态字符串若不归heap所有，不能误free它。

iOS平台配置由集成者修改，F不改：OAuth URL Types/回调与签名Team、Keychain entitlement与独立namespace、Bluetooth usage说明、需要时LocalNetwork/Bonjour/Hotspot能力、SDK要求system frameworks、sherpa native及中文PDF/图片字体资源。哪些必须启用以A/B/D最终报告与真实API为准，不盲目添加宽泛entitlement/ATS例外。

核对后才可执行**unsigned build**，不安装手机：

```bash
QA_NATIVE_LINK_REVIEWED=yes bash docs/test/qa/scripts/mac_preflight.sh --build
# 此命令含 flutter pub get / analyze / test / build ios --debug --no-codesign。
# 若 analyze 的基线lint告警阻断，先准确记录并交集成者修，不加no-fatal抹掉。
```

成功仅填“iOS unsigned build”，仍不是真机测试。真机签名、安装由有权限操作者通过Xcode打开 `app/ios/Runner.xcworkspace`、选择Team和已获准iPhone执行；F不提供自动 `flutter run -d` 会连接未知硬件的脚本。真正device suite由集成者冻结integration_test后显式选择，不能复制不存在的test文件名当可运行命令。

## 3. 按批准范围逐项手工验

1. 不配账号/模型/设备先验默认登录门、空Timeline、不可用服务错误；非空密码不能登录，等超过旧定时器不能成功。顶部录音状态为显示块，不新增录音操控；原胶囊状态入口/布局不变。
2. 账号获准后，系统OAuth取消/拒绝/state不符不登录；合法code→profile→token安全存储→杀App恢复/刷新→退出清除。日志只记录状态码/域名/阶段，不含code/verifier/token。仅获批后执行一次目录和限额文本调用。
3. ASR资源验证后，用合法非敏感短录音和静音片段实际推理；raw/polished/summary同source，raw前后摘要不变。ABC→BCD→重跑BCD和重启保A/B/C/D去重、source稳定；静音stage边界有detector依据；speaker/emotion保不确定，时间来自source。记录加载/推理峰值内存/耗时/长音频取消/后台恢复，不能凭“模型已加载”验完整链路。
4. 指定卡获准后BLE scan→connect→status→filelist→非删除AP取回；对照电量/版本/record/mark，验证下载长度和原文件仍在；timeout/disconnect后无假success。不能使用BLE take代替AP以绕过阻塞。
5. Timeline详情/勾选/所选polished+existing summary总结/来源/反向引用/行动项完成→重启；窄屏安全区/横滑/吸顶Tabs/目录/宽屏双栏/边缘返回不改变。
6. 实际生成五格式文件并交parser；PDF/PNG中文、长文分页/截断需人工看，DOCX系统打开；原生share面板只打开后取消，不发外部账号。不能用toast作为文件或发送证据。
7. Wi-Fi获准指定测试网络后验scan/save/范围外/坏密码/timeout/SD占用，只有native连接回执才成功；本次没有真实网络操作证据。
8. OTA当前只做无包/身份错/校验错/无授权拒绝，不能真刷；若未来另有精确卡+包+版本授权，再按B真实两阶段要求验progress/断连/重连读回版本。无授权的危险case填blocked，不能填pass。

## 4. 真机结果模板

每case写 `case_id, tested_sha, evidence_kind=device, platform, timestamp, authorization_scope, command_or_steps, expected, observed, status, redacted_log_file, artifact_sha256, blocker`。截图必须去掉个人信息/token/SSID密码。可用QA JSON审计结构，但实际值必须从当前运行捕获，不粘贴fixture期望代替证据。

最终分别报告：Linux自动、Mac编译、iPhone真实账号、真实ASR、真实硬件、五格式文件/分享、Wi-Fi、OTA危险操作未验。未通过或未执行处填明确资源/授权/接口阻塞与接手人；不声称“100%真机通过”。
