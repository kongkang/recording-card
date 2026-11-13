# 录音卡 · 上架发布手册

面向要把 `app/` 打包并提交 App Store / Google Play 的工程师。**本文只处理发布相关的事**（签名、版本、图标、商店材料）；功能验收见 `app/test/` 与 `prototype/verify.cjs` 的 62 项对照。

固定身份信息（改之前先同步另一平台与商店后台）：

| 项 | 值 |
| --- | --- |
| iOS bundle id | `com.reai.recordingcard` |
| App Apple ID (iOS) | `6834316655` |
| Android applicationId / namespace | `com.reai.recordingcard` |
| 显示名 | 录音卡 |
| 版本 | pubspec `version: 1.0.0+2026111301` → iOS `1.0.0 (2026111301)`、Android versionName `1.0.0` / versionCode `2026111301` |
| 最低系统 | iOS 15.0、Android 7.0（minSdk 24） |
| 目标系统 | Android targetSdk 36（Play 新应用要求 ≥ 35） |

---

## 0. 发版前一次性准备

1. **Apple 侧**：App Store Connect 创建 App（bundle id `com.reai.recordingcard`），拿到 Team ID 后在 Xcode → Runner → Signing & Capabilities 勾选自动签名（或手动配置 Distribution 描述文件）。
2. **Google 侧**：Play Console 创建应用（包名 `com.reai.recordingcard`），启用 **Play App Signing**（托管签名，你只需要上传密钥）。
3. **政策与支持**：把 `docs/PRIVACY.md` 发布成可公开访问的网页（商店要求填 URL），隐私政策与支持邮箱填 `privacy@reai.chat` / `support@reai.chat`。
4. **版本号**：每次提交前递增 pubspec 的 `version: x.y.z+build`（build 必须递增，不能复用）。当前 1.0.0+1 为首次提审版本。

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

- [ ] 应用图标已替换（两端都不是 Flutter 默认蓝 logo），iOS 图标无 alpha 通道
- [ ] 显示名为「录音卡」，bundle id / 包名为 `com.reai.recordingcard`
- [ ] 版本号 1.0.0 (1)，构建号大于上一版
- [ ] 隐私政策 URL 可公开访问，内容与 `docs/PRIVACY.md` 一致，生效日期同步
- [ ] 商店截图 / 描述 / 关键词 / 分类（工具类）齐全
- [ ] 崩溃兜底已安装（`installCrashHandlers()`），关于页可显示版本号

**iOS**

- [ ] `Info.plist` 蓝牙、本地网络用途文案通过法务确认
- [ ] `NSBonjourServices` 的服务类型与固件实际广播一致（见下方待确认项）
- [ ] `ITSAppUsesNonExemptEncryption=false` 与实际情况相符
- [ ] 审核备注写清「需要硬件设备」，附演示视频或设备借用说明
- [ ] 真机（非模拟器）验证：蓝牙连接、同步、导出分享

**Android**

- [ ] `key.properties` 与 keystore 已备份，且未入库
- [ ] `app-release.aab` 用的是 release 证书
- [ ] 数据安全表单与敏感权限声明已提交
- [ ] Android 15+ 真机确认 edge-to-edge 下顶栏/底栏未被遮挡
- [ ] 动态权限首次拒绝、二次拒绝（不再询问）两条路径文案正常

---

## 5. 待人工确认的开放项（提交前必须逐条落实）

| # | 事项 | 现状 | 确认人 |
| --- | --- | --- | --- |
| 1 | Bonjour 服务类型 `_rc._tcp` / `_http._tcp` 是否与固件广播一致 | 按「Wi-Fi 配网 + 本地 AP」估计填写，未与固件对齐 | 固件负责人 |
| 2 | Wi-Fi 配网实际使用 HTTP 明文还是 HTTPS | App 端未启用明文流量；若设备只提供 `http://192.168.x.x` 配网页，需要为局域网地址加 `networkSecurityConfig` 例外 | 固件 + 客户端 |
| 3 | 云端转写服务端「30 天保留 / 15 天内删除」是否有后端实现支撑 | 目前是政策承诺，需后端确认 | 后端负责人 |
| 4 | 「注销账号」入口是否已在设置页实装 | 本手册按产品设计写入政策，需 UI 落地 | 客户端 |
| 5 | 隐私 / 支持邮箱域名 `reai.chat` 可用性 | 政策与商店都用该域名，需确认可收信 | 运营 |
| 6 | iOS 是否需要保留横屏 | 当前 `Info.plist` 保留左右横屏（按既定决策）；若审核或设计改为仅竖屏，删掉两项即可 | 设计 + 客户端 |

---

## 6. 本地静态校验（不跑完整构建时的最快自检）

```bash
cd app
plutil -lint ios/Runner/Info.plist
plutil -lint ios/Runner.xcodeproj/project.pbxproj
xmllint --noout ios/Runner/Base.lproj/LaunchScreen.storyboard
xmllint --noout android/app/src/main/AndroidManifest.xml android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
flutter analyze && flutter test
```

## 登录与模型配置（2026-11-08 起）

- **OAuth 客户端**：默认复用 reai_mobile_app 的 public client
  （`RC_OAUTH_CLIENT_ID` 编译默认 `58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo`，
  回调 `reai-mobile://callback`，iOS Info.plist 与 Android intent-filter 均已注册该 scheme）。
  换自家客户端时用 `--dart-define=RC_OAUTH_CLIENT_ID=... --dart-define=RC_OAUTH_REDIRECT=...`，
  并同步改两端回调注册，否则授权回不来。
- **模型名**：不再硬编码。登录后 App 调 `GET /api/model-gateway/v1/models`，
  按 `capabilities` 选 ASR（`asr`）与文本（`text`/`chat`）。也可用
  `--dart-define=RC_MODEL_ASR=... --dart-define=RC_MODEL_REFINE=...` 显式覆盖。
- **后端地址**：`RC_API_BASE` 编译默认 `https://block2-api.wainao.chat`。

## 微信登录配置（2026-11-13 起）

客户端只持有微信一次性授权码，换 token 由后端 `/oauth/token` 扩展 grant
（`urn:wainao:params:oauth:grant-type:wechat`）完成；AppSecret 只在后端。

- **AppID 两处同值**（不变式，不一致则授权回不来）：
  1. `app/ios/Flutter/Wechat.xcconfig` 的 `WECHAT_APP_ID`（展开为 Info.plist 的 `$(WECHAT_APP_ID)` 回调 scheme；未获批前用占位串 `rc-wechat-disabled`，防空 scheme 触发 App Store ITMS-90158）；
  2. 构建参数 `--dart-define=RC_WECHAT_APP_ID=wx...`（兼容回退 `WECHAT_APP_ID`；Dart 侧 `OAuthConfig.isWechatConfigured` 严格校验 `wx` 前缀，占位串/空串均判未配置 → 登录页隐藏微信按钮，fail-closed）。
- **iOS 前置（一次性）**：
  1. Apple Developer 后台为 App ID（开发 `dev.kongkang.recordingCard` 与正式 `com.reai.recordingcard`）开启 **Associated Domains** capability（`Runner.entitlements` 已声明 `applinks:app.cn.reai.com`，三个 build configuration 均已挂载）；
  2. `https://app.cn.reai.com/.well-known/apple-app-site-association` 的 `details` 同时包含两个 appID、paths `/link/*`（改 AASA 后 Apple CDN 缓存 24~48h）；
  3. 微信开放平台登记「录音卡」移动应用：iOS bundle id + Universal Link `https://app.cn.reai.com/link/`；Android 侧补登记包名 + 签名 MD5（登记前 Android 真机微信登录不可用）。
- **后端前置**：`/oauth/token` 微信 grant 支持可选 `wechat_app_id` 表单字段（多微信应用路由对应 Secret）；账号归一以 **unionid** 为准（同一主体多应用的 openid 不同）。
- **联调自检**：
  1. 真机装包后在「设置 → Safari → 高级」清 Cookie 不需要；微信授权页能被 `weixinULAPI://` 拉起即说明 scheme 与 queries 白名单生效；
  2. 授权后回不到 App：依次查 `Wechat.xcconfig` 与 dart-define 是否同值 → AASA 是否含当前 bundle id（`curl -s https://app.cn.reai.com/.well-known/apple-app-site-association`）→ 开放平台登记的 bundle id 是否与实际一致（不一致微信会以 errCode -6 拒绝）；
  3. 后端未放行微信 grant 时 App 报「当前客户端未开通微信登录」（`unsupported_grant_type` 映射）。
- **Android R8**：fluwx 自带 consumer-proguard 规则；出包前跑 `flutter build apk --release -Prust.skip=true` 确认混淆构建不挂。

## 平台能力现状

| 平台 | 界面/登录/转写/总结/导出 | 蓝牙硬件链路 |
| --- | --- | --- |
| iOS | ✅ | ✅ 已验证（Rust 静态库链入，release 二进制有导出符号，真机扫描执行） |
| Android | ✅ | ⚠️ **未接通**：Rust 桥目前只编了 iOS 静态库，Android 需要交叉编译 `.so` +
  为 btleplug 提供 JavaVM（`ndk_context` / `JNI_OnLoad`）。当前 Android 包会显示
  「此设备不支持连接录音卡」，其余功能正常。 |

## 验收命令

```sh
cd app
flutter analyze && flutter test                     # 108 项
flutter test integration_test/app_boot_test.dart -d <deviceId>     # 冷启动冒烟
flutter test integration_test/hardware_probe_test.dart -d <deviceId> # 硬件在环（需卡在广播）
flutter build ipa     # iOS 上架包
flutter build appbundle  # Android 上架包
```
