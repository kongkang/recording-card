# 录音卡真机测试交接

本轮代码位于独立分支 `feat/full-flow-device-ready-20261108`，不合并 `master`。HTML 原型保持只读，现有布局、导航和交互基线保留。

**当前状态：**完整依赖和生产组合根已纳入候选。最终沙盒回归为 **220 项 Flutter 测试通过、无跳过，11 项 Rust 测试通过，Flutter analyze 无问题**。这次 Flutter 验证实际加载 Rust 动态库、已校验 SenseVoice 权重和 Silero VAD，使用官方非敏感测试音频；不是只跑 Mock。它证明 Linux 下的代码与 native 推理，不等同 iPhone 蓝牙/推理/签名安装通过。macOS CI 会另外验证 iOS 无签名构建，结果见当前分支 Actions。

## 1. 获取代码与构建工具

```bash
git clone --branch feat/full-flow-device-ready-20261108 \
  https://github.com/kongkang/recording-card.git
cd recording-card
rustup target add aarch64-apple-ios
rustup component add llvm-tools
```

Mac 需要 Flutter **3.47.9 stable / Dart 3.13.7** 或满足本工程约束的兼容版本，Rust 至少1.93（本轮测试1.99.1），Xcode、CocoaPods、测试 iPhone 和自己的开发者签名。大型 ASR 权重不进 Git；小型 MIT Silero VAD 和中文导出字体已随 App 打包，许可文件保留。

`app/pubspec.yaml` 与 `pubspec.lock` 一并提交。`sherpa_onnx` 与 `sherpa_onnx_ios` 固定 **1.13.3**，不可随意升到名称不同的 iOS framework；本轮已验证的 Linux native 插件为1.13.8。依赖包含 http/crypto、secure storage、OAuth launcher、path_provider/connectivity/shared_preferences、pdf/share_plus/archive；`share_plus` 采用12.0.2兼容线。

网络插件固定 `connectivity_plus 7.0.0`。第一轮实际 macOS CI 在 Xcode16.4 / iOS18.5 SDK 下发现自动升级到7.3.2后引用不存在的 `NWPath.isUltraConstrained`；已改为精确版本，避免用户首次构建再遇到同一新SDK API阻断。

第二轮实际 CI 捕获旧 Xcode `nm` 无法解析 Rust1.99预构建对象的 LLVM23嵌入段。现在符号检查使用 `scripts/rust_nm.sh` 定位当前 Rust 同版本 `llvm-nm`，缺组件会明确停止，不忽略错误、不跳过四个FFI定义验证。Rust标准库对象已核验为原生arm64 Mach-O，不能把符号检查工具的不兼容当成模型或业务假成功。

第三轮已进入最终原生链接，Xcode16的 Debug Dylib模式与`KEEP_PRIVATE_EXTERNS`冲突。`CardBridge.xcconfig`显式关闭 `ENABLE_DEBUG_DYLIB`，保留原有架构/符号验证，让Dart process lookup使用主可执行文件中的FFI；不要为绕过链接而删除符号保留配置。

## 2. 临时复用现有 OAuth 客户端

按本次要求，先用已获准参考 public client 注册跑通，再改客户端 ID。**复用客户端注册不是复制账号 Token。** 登录仍在官方 OAuth 授权页由已授权账号完成，保留 PKCE、state、精确 callback、Token 安全存储和刷新。

```bash
cp config/device.reai-reference.example.json config/device.public.json
```

此模板明确启用 `RC_OAUTH_REUSE_REFERENCE_CLIENT=true`，仅允许原始 public ID `58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo` 与精确 `reai-mobile://callback`。Token 存储仍为独立的 `recording_card` namespace。**测试 iPhone 上不能同时安装另一款接收 `reai-mobile` scheme 的参考 App；先卸载参考 App或改用另一台测试手机。** 我们不会自行卸载你的应用；如有参考 App 本地数据，先备份后由你决定。

服务端是否继续允许复用该注册、当前账号的 scope 和模型权限，仍需要真实授权页验证。发生 `invalid_client/redirect` 应核对服务器登记，不绕过白名单。正常独立注册模式使用 `device.public.example.json` 和 `recording-card://callback`；后续换 ID 时同时登记回调、切换配置并重新登录。

`config/device.public.json` 已忽略，禁止放 access/refresh token、password 或 secret。构建脚本从同一配置生成忽略的 `OAuthLocal.xcconfig`，并核验实际 Runner callback；Android 从相同 Dart defines 生成 placeholder。仅改 JSON 而直接绕过脚本 Xcode 构建可能留旧配置，改配置后重跑脚本。

## 3. 本地模型准备

参考模板已填固定官方 ONNX 下载 URL，精确大小/SHA256 与 ReAI mobile 注册表和本次实际下载一致。App 可下载到 `<ApplicationSupport>/recording_card/models`，不会上传音频。首次约230MB下载和 native 初始化会增加等待时间。

审阅 `app/lib/services/transcription/NOTICE.md` 中的 **模型权重许可** 后，在你的 `device.public.json` 中明确设置：

```json
"RC_ASR_LICENSE_ACCEPTED": true,
"RC_ASR_ALLOW_DOWNLOAD": true
```

模板默认不代用户接受权重许可；如果暂时只测 OAuth/设备，将 `RC_ASR_ALLOW_DOWNLOAD` 设为 false。不提供许可确认或模型时，ASR明确报错，不生成假转写。下载逐跳仅允许 `huggingface.co` 和 `us.aws.cdn.hf.co`，完成后校验固定hash；如测试网络无法访问，可配置你审核过的镜像，但文件必须匹配同一规格。

Silero VAD 已内置并校验，用于给长静音提供真实证据；如配置 `RC_VAD_URL/SIZE/SHA256`，使用该显式模型而不覆盖它。没有真实语音区间的证据时，不把蓝牙断流或空 ASR 文字当静音。

Mac/沙盒本地 native 冒烟可使用：

```bash
python3 scripts/prepare_asr_models.py --accept-model-license --with-fixture
```

脚本仅下载固定模型和上游公开 `zh.wav` 到用户缓存，不请求账号、云模型或用户录音。真实 iPhone 模型仍由 App 私有目录管理，不会把沙盒缓存当作手机已经安装。

## 4. 模型目录与首次文本模型

`RC_TEXT_MODEL` 可留空。第一次由用户触发分析时，App 从登录账号的真实授权 text 目录按服务端目录顺序选择一次，并绑定当前 OAuth identity epoch；退出/换账号重新选择。**不是按价格选模型**。如果要固定服务商或费用，请配置该账号获批的精确 ID。

指定 ID 无权限、目录无文本模型、已选模型撤权或请求失败均报错，不自动换另一款付费模型。启动不发 completion；使用录音分析、自动润色或手动总结时才实际请求云端文本模型。测试前确认账号额度，首次建议非敏感短录音，避免把长历史录音直接送云端。

## 5. 构建和安装

先做不访问网络服务/设备的公开配置校验：

```bash
python3 scripts/validate_public_config.py config/device.public.json
bash scripts/run_ios_device.sh --build
```

`--build` 在 Mac 执行 pub get → analyze/test → Rust check/test → Pods → iOS unsigned debug build → 设备架构/FFI符号/callback核验。首次干净签出先使用 `--build`；`--check` 的 Pods检查要求已完成依赖准备，不能把缺少Pods的首次check当业务错误。

无签名 `Runner.app` **不是可直接安装的签名 IPA**。打开 `app/ios/Runner.xcworkspace`，在 Runner 的 Signing & Capabilities 选择自己的 Team，确认唯一 Bundle ID、测试手机开发者模式和信任，保持脚本生成的回调配置。

随后：

```bash
flutter devices
RC_DEVICE_RUN_APPROVED=yes RC_IOS_DEVICE_ID=<你的测试iPhone-ID> \
  bash scripts/run_ios_device.sh --run
```

此命令安装/启动前需要显式手机 ID，使用本机已有签名。脚本不会刷写固件、取走设备源文件或替你确认账号授权。macOS CI 默认采用独立 `recording-card` 配置且不开模型下载，仅检验编译；测试复用 OAuth 时仍按上面兼容配置在你的 Mac 重新签名构建。

## 6. 建议真机测试顺序

1. **登录：**OAuth授权→profile验证→会话恢复；取消/拒绝、退出、再次登录不出现非空密码成功或旧会话复活。
2. **设备：**从现有状态胶囊扫描/连接专用测试卡，核对电量、版本和录音状态。连接后可能按已保存“持续录音”策略启动 App 所有的录音/实时传输，先确认测试卡和可用数据授权。
3. **实时短录音：**说一段非敏感内容，跨几个默认30秒切片，观察本地分片→真实ASR→原始页→润色对话。缺口开启新epoch，不跨丢失音频拼接时间，也不编造设备绝对时钟。
4. **窗口/阶段：**新增切片按 A→AB→ABC→BCD 更新已有润色；原文不可被云端覆盖。真实VAD长静音或终态封阶段，Timeline增加阶段摘要。确认原始/对话/阶段来源一致、重启后能恢复和重试。
5. **手动总结：**勾选多个来源，验证结果内容变化、溯源合法、行动项和路由重启保留；既有阶段摘要只在来源完整选中时进入prompt。不包含未选窗口上下文，必要时舍弃不安全的润色而保留所选原文。
6. **导出：**五种格式实际生成文件，检查中文、长文、来源/不确定性及行动项；打开iPhone/iPad系统分享面板即可，不必外发文件。
7. **设置/异常：**六开关的实际业务效果、断连/重连、缺模型、无授权模型、云失败、取消和重启恢复。模型取消不能保证已经发出的服务端请求停止计费。

## 7. 上传、Wi-Fi、OTA与未验证项

**上传**需实际 `RC_UPLOAD_URL/HOSTS`、multipart/回执合约，以及原始录音上云与 OAuth bearer 授权。默认关闭；同步下载或 HTTP 2xx 不冒充已上传。可以先验证实时主流程；历史AP取回和同步上传另按真实配置验证。

**AP/Wi-Fi**需测试卡支持和手机手动加入其网络。录音中访问SD会冲突；App不暗停他人已有录音，不默认走可能删源的BLE take。AP同步取回大小写匹配的 `.txt/.mrk`，保留原侧车；MRK秒偏移严格解析。live mark通知的精确音频映射尚未接完，不能把该项算完整实测。

**OTA**接口和两阶段任务已实现，但必须提供精确可信清单/包摘要/版本/目标设备并在 App 确认，不在无人值守测试中刷卡。缺清单不显示伪更新，不用定时器报成功。

尚无实际账号授权、iPhone安装/蓝牙/ASR、锁屏后台、功耗、长音频内存、AP切网恢复、原生分享或真设备两阶段OTA证据。SenseVoice保存实际token时间点、情绪等元数据；它没有真实speaker embeddings，本轮匿名说话人推测不等于声纹身份识别。
