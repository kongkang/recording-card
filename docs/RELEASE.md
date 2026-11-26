# 录音卡 · 上架发布手册

面向要把 `app/` 打包并提交 App Store / Google Play 的工程师。**本文只处理发布相关的事**（签名、版本、图标、商店材料）；功能验收见 `app/test/` 与 `prototype/verify.cjs` 的 62 项对照。

固定身份信息（改之前先同步另一平台与商店后台）：

| 项 | 值 |
| --- | --- |
| iOS bundle id | `com.reai.recordingcard` |
| App Apple ID (iOS) | `6834316655` |
| Apple Team ID | `35N5SGDE59` |
| App Store Connect SKU | `recording-card-ios` |
| TestFlight 公开邀请链接 | https://testflight.apple.com/join/fMWkZSv5 （`publicLinkId`: `fMWkZSv5`） |
| Android applicationId / namespace | `com.reai.recordingcard` |
| 显示名 | 录音卡 |
| 版本 | pubspec `version: 1.0.0+2026112601` → iOS `1.0.0 (2026112601)`（主 App / 扩展 / Watch 共用 `FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`）、Android versionName `1.0.0` / versionCode `2026112601`（当前 TestFlight 外部测试构建：`1.0.0 (2026112601)`） |
| 隐私政策 / 技术支持网页 | 隐私政策 `https://ai-card.app.reai.com/privacy.html` · 技术支持 `https://ai-card.app.reai.com/support.html` |
| 最低系统 | iOS 15.0、Android 7.0（minSdk 24） |
| 目标系统 | Android targetSdk 36（Play 新应用要求 ≥ 35） |

---

## 0. 发版前一次性准备

1. **Apple 侧**：App Store Connect 创建 App（bundle id `com.reai.recordingcard`），拿到 Team ID 后在 Xcode → Runner → Signing & Capabilities 勾选自动签名（或手动配置 Distribution 描述文件）。
2. **Google 侧**：Play Console 创建应用（包名 `com.reai.recordingcard`），启用 **Play App Signing**（托管签名，你只需要上传密钥）。
3. **政策与支持**：`site/privacy.html`（`https://ai-card.app.reai.com/privacy.html`）与 `site/support.html`（`https://ai-card.app.reai.com/support.html`）随 `site-pages.yml` 自动部署到官网；隐私政策与支持邮箱填 `privacy@reai.chat` / `support@reai.chat`。
4. **版本号**：每次提交前递增 pubspec 的 `version: x.y.z+build`（build 必须递增，不能复用）。iOS LiveActivity 与 BackgroundDownloadHandler 通过 `ExtensionVersion.xcconfig` 自动同步主端版本号，Watch targets 通过 `watch/Config/Shared.xcconfig` 自动同步。

---

## 1. Android 发版

### 1.1 生成上传密钥（一次性，**密钥不入库**）

```bash
cd app/android
keytool -genkeypair -v \
  -keystore app/upload-keystore.jks \
  -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload \
  -dname "CN=ReAI, OU=Mobile, O=ReAI, L=Beijing, ST=Beijing, C=CN"
```

- 有效期 10000 天（≈27 年）：Google Play 要求密钥在 2033 年后仍有效。
- 生成后**立刻备份** keystore 与口令（密码管理器 + 离线介质）。丢失后无法用同一密钥更新已上架应用。
- `android/.gitignore` 已忽略 `key.properties`、`*.jks`、`*.keystore`，不要用 `git add -f` 绕过。

### 1.2 配置签名

```bash
cd app/android
cp key.properties.example key.properties
# 填入四个字段：storePassword / keyPassword / keyAlias / storeFile
```

`storeFile` 可写绝对路径，或相对 `app/android/app/` 的路径（默认 `upload-keystore.jks`）。

`app/android/app/build.gradle.kts` 的行为：

- 有 `key.properties` → 用 release keystore 签名；
- 没有 → 回退 debug 签名构建并**打印醒目警告**，保证新机器 / CI 能出包自测，但产物不能上架。

### 1.3 出包与校验

```bash
cd app
flutter build appbundle --release      # 产物 build/app/outputs/bundle/release/app-release.aab
# 需要 APK 自测时：
flutter build apk --release
```

校验签名与体积：

```bash
# 确认用的是 release 证书（不是 debug）
$ANDROID_HOME/build-tools/35.0.0/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk | head
# 看 AAB 里的权限与 targetSdk 是否符合预期
bundletool dump manifest --bundle build/app/outputs/bundle/release/app-release.aab | head -40
```

### 1.4 上传 Play Console

1. 内部测试轨道先发一版（验证签名与安装）；
2. 填写 **数据安全表单** → 按 `docs/PRIVACY.md` 附表逐项填；
3. 填写 **敏感权限声明**：`BLUETOOTH_SCAN`（含 `neverForLocation` 已声明）、`NEARBY_WIFI_DEVICES`、`ACCESS_FINE_LOCATION`（`maxSdkVersion=30`）需要说明是硬件配套必需；
4. 上传商店素材（图标由构建产物提供，商店列表图标另需 512×512 PNG）；
5. 提交审核。

### 1.5 已知注意点

- **targetSdk 36 强制 edge-to-edge**：状态栏/导航栏透明，界面必须靠 `SafeArea` 撑住。提审前在 Android 15+ 真机确认顶栏与底栏没有被系统栏压住。
- Play 会对 `ACCESS_FINE_LOCATION` 的声明做人工核查，说明文案要写清「老系统 BLE 扫描的系统要求，不用于定位」。
- release 已开启 `isMinifyEnabled` + `isShrinkResources`：若线上出现插件相关的 `ClassNotFoundException`，优先在 `app/android/app/proguard-rules.pro` 补规则，不要直接关掉压缩。

---

## 2. iOS 发版

### 2.1 签名

1. Xcode 打开 `app/ios/Runner.xcworkspace`（**不是** `.xcodeproj`）；
2. Runner → Signing & Capabilities：Team 选公司团队，Bundle Identifier 确认为 `com.reai.recordingcard`；
3. 确认 `ios/Runner/Info.plist` 里的用途文案已过法务（蓝牙、本地网络）——审核会因为文案含糊打回。

### 2.2 构建

```bash
cd app
flutter build ipa --release     # 产物 build/ios/ipa/*.ipa
```

- Rust 桥的静态库由 Xcode 的 **Build Rust Bridge** 阶段自动编译（`app/rust/build-ios.sh`，仅 `iphoneos` 生效），干净检出也能直接构建。
- 需要 `rustup target add aarch64-apple-ios`（脚本会检查并给出明确报错）。

### 2.3 上传与提审

```bash
xcrun altool --upload-app -f build/ios/ipa/录音卡.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
# 或用 Xcode Organizer / Transporter 图形界面上传
```

App Store Connect 需要填：

- **隐私**：按 `docs/PRIVACY.md` 附表（不用于追踪、无广告标识）；
- **加密合规**：`Info.plist` 已声明 `ITSAppUsesNonExemptEncryption=false`（只用系统 HTTPS，不含自研加密算法）；
- **出口合规**、**年龄分级**（建议 4+，但需在描述里说明面向成年用户）；
- 审核备注里说明：**App 需要硬件录音卡才能使用**，并附演示视频或测试账号，否则会因「无法完整体验功能」被拒。

### 2.4 图标与启动屏

- AppIcon 由 `app/assets/icon/app_icon.svg` 生成，**不带 alpha 通道**（带 alpha 会被 App Store 直接拒）；
- LaunchScreen 为米白底 + 应用名，符合审核对「启动屏不得像广告」的要求。

### 2.5 TestFlight 分发信息与公开邀请链接

- **公开邀请链接**：https://testflight.apple.com/join/fMWkZSv5 （`publicLinkId`: `fMWkZSv5`，已启用；可直接分享给用户，无需逐个收集邮箱）。
- **测试用户加入步骤**：
  1. 在 iPhone 上安装苹果官方 **TestFlight** App；
  2. 打开上面的邀请链接；
  3. 在 TestFlight 中点击「接受 / 安装」。

#### 测试组配置

| 测试组名称 | 类型 | Group ID | 公开链接与容量配置 |
| --- | --- | --- | --- |
| `Recording Card Internal Testing` | 内部测试组 | `df549b4d-656d-4374-9433-7224b64271db` | `hasAccessToAllBuilds: true` |
| `Recording Card External Testing` | 外部测试组 | `4fc99575-cdf1-4295-9535-0ba901375c32` | `publicLinkEnabled: true`，`publicLinkId: fMWkZSv5`，`publicLinkLimitEnabled: false`（未设额外上限，受 TestFlight 单 App 10,000 人总上限约束） |

#### 当前已过审外部测试构建（截至 2026-11-26）

- **`1.0.0 (2026112601)`**：Build ID `53b0b4bd-edb0-4b15-99a1-9e3518c434ab`，上传日期 `2026-11-26`，有效期至 `2027-02-24`，状态 `VALID` / `APPROVED` / `IN_BETA_TESTING`（内外部测试均为 `IN_BETA_TESTING`，已开启 `autoNotifyEnabled=true` 全员自动通知，已写入 `zh-Hans` `whatsNew` 说明长录音总结防空正文/8192 自动扩容重试及 V2 稳定性与功能更新），出口合规 `usesNonExemptEncryption=false`（统一主端 + Watch 包）。
- **`1.0.0 (2026112501)`**：Build ID `38a8332e-3851-4fac-a7d0-9a6d9782326f`，上传日期 `2026-11-25`，有效期至 `2027-02-23`，状态 `VALID` / `APPROVED` / `IN_BETA_TESTING`（内外部测试均为 `IN_BETA_TESTING`，已开启 `autoNotifyEnabled=true` 全员自动通知），出口合规 `usesNonExemptEncryption=false`（统一主端 + Watch 包）。
- **`1.0.0 (2026112101)`**：Build ID `e059e3ff-06ae-4de5-b241-b600857d83a5`，上传日期 `2026-11-21`，有效期至 `2027-02-18`，状态 `VALID` / `APPROVED` / `IN_BETA_TESTING`，出口合规 `usesNonExemptEncryption=false`（手机与手表同一包）。

#### App Store Connect API 管理说明与安全边界

- **查询 / 更新外部组**：`GET` / `PATCH https://api.appstoreconnect.apple.com/v1/betaGroups/4fc99575-cdf1-4295-9535-0ba901375c32`（可切换 `publicLinkEnabled`，或配置 `publicLinkLimitEnabled` / `publicLinkLimit` 限制加入人数）。
- **安全边界**：本仓库为公开开源仓库，**严禁将 `.p8` 私钥、ASC API Key ID、Issuer ID、测试员邮箱或个人联系方式提交入库**；本机调用时从 `~/.private_keys/AuthKey_<KEY_ID>.p8` 与环境变量读取。
- **JWT 注意**：ASC API ES256 JWT 的 `exp - iat` 不得超过 20 分钟（建议 `900s`），否则会返回 `401 NOT_AUTHORIZED`。

---

## 3. 重新生成图标

唯一设计真源：`app/assets/icon/app_icon.svg`（1024×1024）。改了设计后：

```bash
cd app
bash assets/icon/render_icons.sh
```

脚本会：

1. 用 `rsvg-convert` 渲染 15 个 iOS 尺寸 → `ios/Runner/Assets.xcassets/AppIcon.appiconset/`（同时用 `strip_alpha.py` 去掉 alpha）；
2. 渲染 Android 传统图标 5 个密度（48/72/96/144/192）→ `android/app/src/main/res/mipmap-*/ic_launcher.png`；
3. 渲染自适应图标前景 + Android 13 主题图标（108/162/216/324/432）→ `mipmap-*/ic_launcher_foreground.png`、`ic_launcher_monochrome.png`；
4. 渲染旧系统启动屏标识 → `res/drawable-xxhdpi/rc_splash_logo.png`。

生成后自检（关键：确认不是模板图、iOS 无 alpha）：

```bash
cd app
file ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png   # 期望 8-bit/color RGB
md5 -q android/app/src/main/res/mipmap-mdpi/ic_launcher.png                     # 与替换前不同
# 用 Xcode 的工具链验证整套图标能编译（会报 alpha / 尺寸问题）
xcrun actool --compile /tmp/iconcheck --platform iphoneos \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist /tmp/iconcheck.plist \
  --target-device iphone --target-device ipad ios/Runner/Assets.xcassets
# Android 资源（含自适应图标 XML）语法检查
$ANDROID_HOME/build-tools/35.0.0/aapt2 compile --dir android/app/src/main/res -o /tmp/res-flat/
```

依赖：`brew install librsvg`（提供 `rsvg-convert`）、`python3`（`strip_alpha.py` 只用标准库）。

---

## 4. 上架检查清单

**通用**

- [x] 应用图标已替换（两端都不是 Flutter 默认蓝 logo），iOS 图标无 alpha 通道
- [x] 显示名为「录音卡」，bundle id / 包名为 `com.reai.recordingcard`
- [x] 版本号已在 `app/pubspec.yaml` 递增，构建号大于上一版（所有 iOS / Watch 扩展自动同步：`1.0.0+2026112601`）
- [ ] 公开隐私政策页（`https://ai-card.app.reai.com/privacy.html`）与技术支持页（`https://ai-card.app.reai.com/support.html`）已发布上线，生效日期（`2026-11-24`）一致
- [ ] 商店截图 / 描述 / 关键词 / 分类（工具类）齐全
- [x] 崩溃兜底已安装（`installCrashHandlers()`），关于页可显示版本号，设置页「数据管理 → 清空本机全部数据」与「云端账号授权 → 退出登录」已就位
- [x] 正式版默认隐藏「开发者设置」（连点「版本」7 次开启），登录页未配置/未启用的第三方入口自动隐藏

**iOS / watchOS**

- [x] 5 个 Apple Target（`Runner`、`RecordingCardLiveActivity`、`BackgroundDownloadHandler`、`RecordingCardWatchApp`、`RecordingCardWatchWidgets`）均已配置并挂载 `PrivacyInfo.xcprivacy`
- [ ] `Info.plist` 蓝牙、本地网络、健康与定位用途文案通过法务确认
- [ ] `NSBonjourServices` 的服务类型与固件实际广播一致（见下方待确认项）
- [x] `ITSAppUsesNonExemptEncryption=false` 与实际情况相符
- [ ] 审核备注写清「需要硬件设备」，附演示视频或设备借用说明 + 测试账号
- [ ] TestFlight 内部测试验证：蓝牙连接、Apple Watch 联动、Apple-Hosted Background Assets、微信 Universal Links、导出分享

**Android**

- [ ] `key.properties` 与 keystore 已备份，且未入库（上传密钥指纹需与微信登记签名 `fe80df2054941b4051b7268a8a3fce6b` 对应）
- [ ] `app-release.aab` 用的是 release 证书，且 `abiFilters` 与 `libcard_bridge.so`（默认仅 `arm64-v8a`，全 ABI 需 `RC_ANDROID_ALL_ABIS=1`）匹配
- [ ] 数据安全表单与敏感权限声明已提交
- [ ] Android 15+ 真机确认 edge-to-edge 下顶栏/底栏未被遮挡
- [x] 局域网 SoftAP 明文白名单已通过 `network_security_config.xml` 收敛到设备本地热点 IP，公网强制 HTTPS

---

## 5. 待人工确认的开放项（提交前必须逐条落实）

| # | 事项 | 现状 | 确认人 |
| --- | --- | --- | --- |
| 1 | Bonjour 服务类型 `_rc._tcp` / `_http._tcp` 是否与固件广播一致 | 按「Wi-Fi 配网 + 本地 AP」估计填写，未与固件对齐 | 固件负责人 |
| 2 | 局域网 SoftAP 地址例外与旧版 OTA 域名 | Android `network_security_config.xml` 已仅放行 `192.168.4.1` / `192.168.43.1`；`rust/card_bridge/src/legacy_upgrade.rs` 中 `hdd.dev.reai.com` 需确认是否切生产域名 | 固件 + 客户端 |
| 3 | 云端转写服务端「30 天保留 / 15 天内删除」 | 目前是政策承诺（App 内仅提供「退出登录」与「清空本机全部数据」）；需后端确认转写副本清理 SLA | 后端负责人 |
| 4 | 微信开放平台正式 `wx...` AppID 与 Universal Link / 服务端配置 | **✅ 已完成并真机闭环验证（2026-11-25）**：开放平台「录音卡」（`wx929549126f19f795`）与外脑主端同在 `app@wainao.ai` 主体下，iPhone/iPad Universal Links 已切换为 `https://ai-card.app.reai.com/link/`；`cn.reai.com` 的 `ai-card.app.reai.com` AASA 与 `/link/` 着陆页已部署并经苹果 CDN（`cdn-apple.com`）返回 `HTTP 200 application/json`；`AppSecret` 已加密存入 `block2.wainao.chat/admin/site-secrets`（`WECHAT_LOGIN_MOBILE_SECRET_WX929549126F19F795`），外脑后端 `wainao_editor` PR #2075（`f910ebc56`）已上线支持多移动应用 `wechat_app_id` 路由。Android 上架仍需确保正式 keystore 签名 MD5 匹配 `fe80df2054941b4051b7268a8a3fce6b` | Owner + 后端 |
| 5 | 隐私 / 支持邮箱域名 `reai.chat` 可用性 | 政策与商店都用 `privacy@reai.chat` / `support@reai.chat`，需确认可收信 | 运营 |
| 6 | iOS 是否需要保留横屏 | 当前 `Info.plist` 保留左右横屏（按既定决策）；若审核或设计改为仅竖屏，删掉两项即可 | 设计 + 客户端 |

---

## 6. 本地静态校验（不跑完整构建时的最快自检）

```bash
cd app
plutil -lint ios/Runner/Info.plist ios/Runner/PrivacyInfo.xcprivacy \
  ios/RecordingCardLiveActivity/PrivacyInfo.xcprivacy \
  ios/BackgroundDownloadHandler/PrivacyInfo.xcprivacy \
  ../watch/WatchApp/Info.plist ../watch/WatchApp/PrivacyInfo.xcprivacy \
  ../watch/WatchWidgets/PrivacyInfo.xcprivacy \
  ios/Runner.xcodeproj/project.pbxproj
xmllint --noout ios/Runner/Base.lproj/LaunchScreen.storyboard
xmllint --noout android/app/src/main/AndroidManifest.xml \
  android/app/src/main/res/xml/network_security_config.xml \
  android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
flutter analyze && flutter test
```

## 登录与模型配置（2026-11-08 起）

> 四通道登录架构、未配置/未开通渠道自动隐藏规则、微信启用步骤与真机安装说明详见 [AUTH-LOGIN.md](./AUTH-LOGIN.md)。

- **OAuth 客户端**：默认复用 reai_mobile_app 的 public client
  （`RC_OAUTH_CLIENT_ID` 编译默认 `58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo`，
  回调 `reai-mobile://callback`，iOS Info.plist 与 Android intent-filter 均已注册该 scheme）。
  换自家客户端时用 `--dart-define=RC_OAUTH_CLIENT_ID=... --dart-define=RC_OAUTH_REDIRECT=...`，
  Android 同步用 Gradle 参数 `-Prc.oauthScheme=...`（缺省 `reai-mobile`）保持回调注册一致。
- **首页四通道登录**：
  - **外脑账号登录**：系统安全浏览器打开 `/oauth/authorize`（PKCE S256）；
  - **微信登录**：`fluwx` 原生 OpenSDK（配置合法 `wx...` AppID 且未明确缺失微信客户端时自动展示并可点击；未配置或未安装微信时按 App Store 2.1 / 4.2.3 自动隐藏）；
  - **Apple / Google 登录**：借用外脑 `/oauth/authorize?login_type=apple` 或 `login_type=google`（Android 走 Google 登录时自动切回 Chrome Custom Tabs，规避 WebView 403 拦截）；启动预热请求 `GET /auth/social/providers`，仅展示线上已启用的渠道，未启用的自动隐藏；联调可通过 `--dart-define=RC_SOCIAL_PROVIDERS=apple,google` 显式覆盖可用渠道集合。
- **模型名**：不再硬编码。登录后 App 调 `GET /api/model-gateway/v1/models`，
  按 `capabilities` 选 ASR（`asr`）与文本（`text`/`chat`）。也可用
  `--dart-define=RC_MODEL_ASR=... --dart-define=RC_MODEL_REFINE=...` 显式覆盖。
- **后端地址**：`RC_API_BASE` 编译默认 `https://block2-api.wainao.chat`。
- **端侧语音/声纹模型下载源**：优先级为 `--dart-define=RC_MODEL_BASE=...` 显式覆盖 ＞ iOS 26+ 免费 **Apple-Hosted Background Assets**（`sensevoice-small-int8` v2、`campplus-embedding` v1、`silero-vad` v1）＞ 编译默认外脑 CDN `https://dl.wainao.chat/reai/models`（Android 默认源及低版本 iOS 兜底，两套 CDN 共享同一组 SHA-256 指纹）。

## 微信登录配置（2026-11-13 起）

客户端只持有微信一次性授权码，换 token 由后端 `/oauth/token` 扩展 grant
（`urn:wainao:params:oauth:grant-type:wechat`）完成；AppSecret 只在后端。

- **微信开放平台登记状态（已过审，`AppID: wx929549126f19f795`）**：
  - iPhone / iPad：Bundle ID `com.reai.recordingcard`，目标 Universal Links `https://ai-card.app.reai.com/link/`（原 `https://app.cn.reai.com/link/` 属于外脑 `com.reai.reaiApp`，共用同一路径会导致 iOS 优先唤醒外脑 App，必须切至独立域名）；
  - Android：应用包名 `com.reai.recordingcard`，应用签名 `fe80df2054941b4051b7268a8a3fce6b`；
  - 开发者资质认证：`已认证`（深圳点一几科技有限责任公司），「微信登录」能力：`已获得`（`50000/min`）。
- **AppID 与 Universal Link 配置**（AppID 两处必须同值，不一致则授权回不来；`archive_testflight.sh` 会从 `Wechat.xcconfig` 自动注入 `--dart-define=RC_WECHAT_APP_ID`，并支持可选 `--dart-define=RC_WECHAT_UNIVERSAL_LINK` 覆盖）：
  1. `app/ios/Flutter/Wechat.xcconfig` 的 `WECHAT_APP_ID` 已写入 `wx929549126f19f795`（展开为 Info.plist 的 `$(WECHAT_APP_ID)` 回调 scheme；未填写时可用占位串 `rc-wechat-disabled` 防空 scheme 触发 ITMS-90158）；
  2. 构建参数 `--dart-define=RC_WECHAT_APP_ID=wx929549126f19f795`（兼容回退 `WECHAT_APP_ID`；Dart 侧 `OAuthConfig.isWechatConfigured` 严格校验 `wx` 前缀，非 `wx` 开头判未配置并隐藏按钮）；
  3. Universal Link 默认 `https://ai-card.app.reai.com/link/`（可通过 `RC_WECHAT_UNIVERSAL_LINK` 覆盖），与 `Runner.entitlements` 中 `applinks:ai-card.app.reai.com` 对应。
- **iOS 前置（已全部落实）**：
  1. Apple Developer 后台为 App ID（开发 `dev.kongkang.recordingCard` 与正式 `com.reai.recordingcard`）开启 **Associated Domains** capability（`Runner.entitlements` 已声明 `applinks:ai-card.app.reai.com`，三个 build configuration 均已挂载）；
  2. `ai-card.app.reai.com`（`cn.reai.com` `/etc/nginx/sites-enabled/ai-card.app.reai.com.conf`）已显式接管 `/.well-known/apple-app-site-association`、`apple-app-site-association`（仅含 `35N5SGDE59.com.reai.recordingcard` + `/link/*`，返回 `Content-Type: application/json` HTTP 200）与 `/link/` 兜底页，苹果 CDN（`app-site-association.cdn-apple.com`）已校验生效；
  3. 微信开放平台（`open.weixin.qq.com`）`wx929549126f19f795` iPhone/iPad Universal Links 已切至 `https://ai-card.app.reai.com/link/`，`AppSecret` 已存入 `block2.wainao.chat/admin/site-secrets`（`WECHAT_LOGIN_MOBILE_SECRET_WX929549126F19F795`，不放 `.env`）；Android 打包正式签名 keystore MD5 需匹配 `fe80df2054941b4051b7268a8a3fce6b`。
- **后端多移动应用路由（已上线）**：`/oauth/token` 微信 grant 与 `/my/wechat/bind` 支持可选 `wechat_app_id` 字段（`wainao_editor` PR #2075 / `f910ebc56`），非默认移动应用自动按 `WECHAT_LOGIN_MOBILE_SECRET_<UPPER_APPID>` 解密路由（不影响外脑主端 `wxd9ce5b90974d7c2a`）；账号归一以 **unionid** 为准（同一主体多应用的 openid 不同）。详细故障速查表见 [AUTH-LOGIN.md §4](./AUTH-LOGIN.md#4-微信开放平台启用与全链路配置手册2026-11-25-已上线闭环)。
- **联调自检**：
  1. 真机装包后在「设置 → Safari → 高级」清 Cookie 不需要；微信授权页能被 `weixinULAPI://` 拉起即说明 scheme 与 queries 白名单生效；
  2. 授权后跳到外脑或回不到 App：依次查 `Wechat.xcconfig` 与 dart-define 是否同值 → `curl -sI https://ai-card.app.reai.com/.well-known/apple-app-site-association` 是否返回 `200` + `application/json` 且仅含 `35N5SGDE59.com.reai.recordingcard` → 微信开放平台登记的 Bundle ID 与 Universal Links（`https://ai-card.app.reai.com/link/`）是否与客户端逐字符一致；
  3. 后端未放行微信 grant 时 App 报「当前客户端未开通微信登录」（`unsupported_grant_type` 映射）。
- **Android R8**：fluwx 自带 consumer-proguard 规则；出包前跑 `flutter build apk --release -Prust.skip=true` 确认混淆构建不挂。

## 平台能力现状

| 平台 | 界面/登录/转写/总结/导出 | 蓝牙硬件链路 |
| --- | --- | --- |
| iOS | ✅ | ✅ 已验证（Rust 静态库链入，release 二进制有导出符号，真机扫描/录音/转写/OTA 闭环已验证） |
| Android | ✅ | ✅ **已打通**：`rust/build-android.sh` 编译 `libcard_bridge.so`（`JNI_OnLoad` 注入 `JavaVM`，默认锁定 `arm64-v8a`，全 ABI 用 `RC_ANDROID_ALL_ABIS=1`），`MainActivity` 捕获 `UnsatisfiedLinkError` 防止缺 ABI 闪退；Omi 真机 E2E 已验证通过（详见 `docs/handoff/handoff-2026-11-16-omi-android-ble-e2e.md`）。 |

## 验收命令

```sh
cd app
flutter analyze && flutter test                     # 108 项
flutter test integration_test/app_boot_test.dart -d <deviceId>     # 冷启动冒烟
flutter test integration_test/hardware_probe_test.dart -d <deviceId> # 硬件在环（需卡在广播）
flutter build ipa     # iOS 上架包
flutter build appbundle  # Android 上架包
```
