# 真机测试交接（修复后候选；未宣称真机通过）

工作分支为 `feat/full-flow-device-ready-20261108`，禁止合并 master 或擅自 push/PR。prototype 保持只读，现有 HTML 结构/布局交互不变。沙盒已验证 Flutter analyze/test 与无硬件 Rust/FFI；没有 Mac/Xcode/iOS/Android 构建、签名、安装或真机证据。

## 1. 先冻结依赖，再交给获授权 Mac

按协作边界，最终修复源码 commit **不包含 `app/pubspec.yaml` / `app/pubspec.lock`**；本工作树已用集成者的真实依赖解析进行测试。集成者需 review 并单独提交这两个文件，之后才有可重现的完整 Git 构建候选，不能只 checkout 修复 commit 就称依赖齐全。

当前依赖：`ffi ^2.1.0`、`http ^1.2.0`、`crypto ^3.0.6`、`flutter_secure_storage ^9.2.4`、`flutter_web_auth_2 ^4.1.0`、`path_provider ^2.1.6`、`connectivity_plus ^7.0.0`、`shared_preferences ^2.5.6`、`sherpa_onnx 1.13.3`、`sherpa_onnx_ios 1.13.3`、`pdf ^3.13.1`、`share_plus ^12.0.2`、`archive ^4.6.0`；dev dependency `integration_test sdk:flutter`；字体 asset `lib/services/export/assets/NotoSansSC-Regular.ttf`。保留基线 Flutter/cupertino_icons/flutter_test/flutter_lints。

## 2. 无密钥配置

复制 `config/device.public.example.json` 为已 ignore 的 `config/device.public.json`。只填获批的 public client、URL、模型 ID、权重 size/SHA256、白名单和许可声明；**禁止 token、password、secret**。真实 token 只进独立安全存储。

OAuth 原生 callback 固定 `recording-card://callback`；服务端必须允许本 App 复用该 public client 和精确 redirect。没有登记就不能登录验收。`RC_TEXT_MODEL` 必须为当前账号获授权文本模型，生产不自动替换模型。此任务禁止实际登录或付费请求，后续真实联调需另行授权。

SenseVoice 使用已审核的固定模型/tokens 大小和 SHA256；生产私有模型目录为 `<ApplicationSupport>/recording_card/models`。安装权重或显式受信下载前，需真实许可确认和镜像白名单；默认不会自动下载。Silero 可配置 `RC_VAD_URL`、`RC_VAD_SIZE`、`RC_VAD_SHA256`，文件名 `silero_vad.onnx`，亦使用 `RC_ASR_DOWNLOAD_HOSTS`。三项留空/0为未配置 VAD；填写时 size/hash 必须精确。未配置 VAD不产生“长静音已检测”的假证据。

上传需 `RC_UPLOAD_URL/HOSTS`、`RC_UPLOAD_RAW_CONTRACT_APPROVED`、`RC_UPLOAD_OAUTH_BEARER_APPROVED`，且上传 host 与 OAuth trusted host 交集非空。应取得协议和原始录音上云授权；2xx/本地下载不等于已上传。固件需精确 `RC_FIRMWARE_MANIFEST_JSON` 和测试卡/包单独刷写授权，没有清单不升级。

## 3. Mac 命令及边界

在用户指定并授权的 Mac 上准备 Flutter/Cargo/Rust iOS target、Xcode、CocoaPods、开发者签名和测试 iPhone。不要自动切换到未授权电脑。

```bash
cd /path/to/recording-card
cp config/device.public.example.json config/device.public.json
# 填写获批的公开参数，不要加入凭据。
bash scripts/run_ios_device.sh --check
bash scripts/run_ios_device.sh --build
```

`--check` 仅工具/配置核查，无设备探测、登录、下载、OTA。Linux 必须 exit 2，不能生成签名 IPA。`--build` 在 Mac 执行 pub get → analyze/test → Rust check/test → pod install → unsigned debug iOS build。输出 Runner.app **不是签名 IPA或安装成功**。Runner Xcode phase 为当前 SDK 构建 Rust archive；需要实际验证 iOS15、Pods、symbols、静态链接和签名。

安装/运行必须额外设置 `RC_DEVICE_RUN_APPROVED=yes` 与精确 `RC_IOS_DEVICE_ID`：

```bash
RC_DEVICE_RUN_APPROVED=yes RC_IOS_DEVICE_ID=<获批测试iPhone-ID> \
  bash scripts/run_ios_device.sh --run
```

运行 App 后，连接卡可能按已保存持续录音策略启动 App 所有的录音/实时传输；执行前审阅测试卡/数据授权。AP 切换与 Wi-Fi/固件/账号联调不因脚本能运行而自动获得授权。native system share 可只打开面板，不发给外部账号；iPad origin与各格式实显示需真机核查。

## 4. 分层验收，不跳步骤冒充完成

先验证 Mac archive/Pods/link/sign，再验证获批 OAuth→profile→目录→指定模型调用。之后在专用测试卡确认 BLE 状态、录音启停、实时 WAV 落盘、间断 epoch、终态释放/重新开始、ASR/VAD 真模型、窗口/阶段、Timeline/原始/对话同源、选择总结合法来源、行动项持久化和五格式原生分享。重启恢复须用非敏感测试录音验证，不删除源。

同步按钮仍要求真实上传回执。AP 下载保存大小写配对 `.txt` 和 `.mrk`；MRK 为固件 v0.3.2+ 每行十进制秒偏移，原侧车持久化，坏行/超限明确失败。标记开关只派生解释，不覆写硬件按键绑定。live mark notify 的精确源音频映射仍未提供，本轮不造时间或身份；文件同步路径可获取真实 marks。

VAD 模型缺失则只能验证“无静音证据”，不能拿空 ASR、30秒 BLE 断流或计时器当静音。先前窗口曾含未选上下文时，手动总结会排除该 polished 行，退回所选 raw；不会泄漏未选资料。阶段 context 仅在其完整原始来源全部选中时进入 prompt。

后台锁屏、iOS蓝牙/ASR资源及功耗、原生分享、AP切网恢复、长录音内存/耗电、录音标记映射和真实两阶段 OTA 均未获真机证据；不得写成全功能真实完成。退出/认证失效由 runtime 停止 owned 实时传输、取消并 await 任务、断开 BLE；不停止其他 owner 的 SD 录音。已发送模型请求取消不能保证服务端停止计费。
