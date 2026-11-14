# 录音卡 · 登录体系与四通道启用说明

本文档说明「录音卡」首页四通道登录的架构设计、未审核/未开通前的禁用态（`disabled`）交互规则、微信开放平台过审后的启用步骤，以及真机安装与验证命令。

关联代码与文档：

- 登录页 UI：`app/lib/pages/login_page.dart`
- 鉴权编排与渠道状态机：`app/lib/services/auth_service.dart`
- OAuth 2.0 PKCE & 渠道探测：`app/lib/services/auth/oauth_client.dart`
- 编译期环境配置：`app/lib/services/auth/oauth_config.dart`
- 设置页账号与渠道绑定：`app/lib/pages/settings/setting_sub_page.dart`
- 上架与签名总册：[RELEASE.md](./RELEASE.md)

---

## 1. 设计与架构概览

对标 `reai_mobile_app` 登录体验，首页登录页移除了早期无实际作用的「账号（可选）」输入框（旧 `Key('login-account')`），收敛为**外脑 OVS 统一账号体系下的四个原生风格登录入口**：

| 顺序 | 按钮文案 | Widget Key | 加载态 Key | 底层鉴权链路 |
| --- | --- | --- | --- | --- |
| 1 | **使用外脑账号登录** | `login-submit` | `login-busy` | 外脑 OVS OAuth 2.0 Authorization Code + PKCE S256（`GET /oauth/authorize` → `POST /oauth/token`） |
| 2 | **微信登录** | `login-wechat` | `login-wechat-busy` | `fluwx` 微信 OpenSDK 原生拉起授权码 → 外脑 `POST /oauth/token`（`grant_type=urn:wainao:params:oauth:grant-type:wechat`） |
| 3 | **通过 Apple 登录** | `login-apple` | `login-apple-busy` | 原生 Apple 品牌按钮 + 系统安全认证会话（`ASWebAuthenticationSession`）直达 `GET /oauth/authorize?login_type=apple` |
| 4 | **通过 Google 登录** | `login-google` | `login-google-busy` | 原生 Google 四色 G 品牌按钮 + 系统安全认证会话直达 `GET /oauth/authorize?login_type=google` |

### 为什么 Apple / Google 采用原生按钮 + `login_type` 借用外脑接口？

1. **零客户端密钥、零后端改造即可落地**：外脑后端（`https://block2-api.wainao.chat`）已原生支持 `GET /oauth/authorize?login_type=apple|google` 与公开探测接口 `GET /auth/social/providers`。传入 `login_type` 后，系统认证弹层直接聚焦目标单点登录，完成后仍通过 `reai-mobile://callback` + PKCE S256 换取同一套外脑 Token（`Keychain` 安全存储）。
2. **关于纯客户端 SDK Token 直换**：外脑 `/oauth/token` 当前开放的 `grant_type` 为 `authorization_code`、`refresh_token`、`otp` 与微信扩展 grant，暂未开放客户端直接提交 `sign_in_with_apple` / `google_sign_in` `id_token` 的扩展 grant。后续若后端新增对应 `grant_type`，可在 `AuthService.signInWithApple` / `signInWithGoogle` 内平滑切换，无需改动登录页 UI 结构。

---

## 2. 按钮显示与禁用态（`disabled`）矩阵

在第三方平台审核尚未通过或后端渠道尚未开启前，**登录页保留按钮展示并置为 `disabled`（`onPressed: null`，半透明灰态）**，避免入口消失造成困惑，同时杜绝点击未就绪渠道报错：

| 登录入口 | 显示条件（`shouldShow*`） | 可点击条件（`is*Enabled`） | 当前 `master` 默认状态（连 `block2-api.wainao.chat`） |
| --- | --- | --- | --- |
| **使用外脑账号登录** | 常驻显示 | `OAuthConfig.isConfigured == true` 且当前无其他登录进行中 | **显示 · 可点击（enabled）** |
| **微信登录** | 未配置 `RC_WECHAT_APP_ID` 时常驻显示；已配置 `wx...` AppID 时，仅在本机明确未安装微信（`cachedIsInstalled == false`）时按 App Store 4.2.3 规范隐藏 | 已配置合法 `wx...` AppID，且微信客户端未明确缺失，且无其他登录进行中 | **显示 · 禁用（disabled）**（待微信开放平台审核通过后配置 AppID 点亮） |
| **通过 Apple 登录** | 常驻显示 | `OAuthConfig.isConfigured == true` 且启动预热 `GET /auth/social/providers` 返回含 `"apple"` | **显示 · 可点击（enabled）**（线上已开启 `apple`） |
| **通过 Google 登录** | 常驻显示 | `OAuthConfig.isConfigured == true` 且启动预热 `GET /auth/social/providers` 返回含 `"google"` | **显示 · 禁用（disabled）**（线上暂未开启 `google`，开启后自动点亮） |

> **并发与防重入保护**：四个入口共用 `AuthService.activeChannel` 与 `_signInEpoch` 互斥锁——任一入口发起登录期间，该按钮切换为对应 spinner，其余三个按钮全部临时置灰禁点；退出登录或切换账号时旧授权回调自动作废。

---

## 3. 编译期配置参数（`--dart-define`）

| 参数名 | 默认值 | 说明 |
| --- | --- | --- |
| `RC_API_BASE` | `https://block2-api.wainao.chat` | 外脑后端与模型网关根地址 |
| `RC_OAUTH_CLIENT_ID` | `58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo` | OVS OAuth 公共客户端 ID（与 `reai_mobile_app` 共用） |
| `RC_OAUTH_REDIRECT` | `reai-mobile://callback` | OAuth 授权完成回调 URI（已在 iOS `Info.plist` / Android `AndroidManifest.xml` 注册） |
| `RC_WECHAT_APP_ID` | 空（未配置） | 微信开放平台移动应用 `AppID`（必须以 `wx` 开头；兼容回退 `WECHAT_APP_ID`） |
| `RC_SOCIAL_PROVIDERS` | 未定义（走线上 `/auth/social/providers` 探测） | 联调覆盖社会化登录启用列表，例如 `--dart-define=RC_SOCIAL_PROVIDERS=apple,google` |

---

## 4. 微信开放平台审核通过后的启用步骤

微信开放平台移动应用「录音卡」审核通过、拿到正式 `wx...` AppID 后，按以下三步激活微信登录按钮：

1. **修改 iOS URL Scheme 配置**
   编辑 `app/ios/Flutter/Wechat.xcconfig`，将占位符替换为正式 `wx...` AppID：
   ```xcconfig
   WECHAT_APP_ID=wx你的正式AppID
   ```
   > **不变式**：`Wechat.xcconfig` 中的 `WECHAT_APP_ID` 必须与构建参数 `--dart-define=RC_WECHAT_APP_ID=wx...` 完全一致，否则微信客户端无法跳回 App。AppSecret 仅配置在外脑后端，严禁写入客户端仓库。
2. **确认 Universal Link 与后端配置**
   - `Runner.entitlements` 已配置 `applinks:app.cn.reai.com`，默认 Universal Link 为 `https://app.cn.reai.com/link/`；
   - 确认 `https://app.cn.reai.com/.well-known/apple-app-site-association` 包含 `35N5SGDE59.com.reai.recordingcard` 且覆盖 `/link/*`；
   - 确认外脑后端已配置该 `wx...` AppID 对应的 AppSecret。
3. **带参构建或安装**
   ```bash
   cd app
   flutter run --release -d 00008140-000C4CE23862201C \
     --dart-define=RC_WECHAT_APP_ID=wx你的正式AppID
   ```
   启动后本机装有微信时，「微信登录」按钮将自动由 `disabled` 变为可点击状态。

---

## 5. Google 登录启用方式

- **线上正式开启**：在外脑后端管理台启用 Google 社会化登录，使 `GET https://block2-api.wainao.chat/auth/social/providers` 返回列表中包含 `"google"`。客户端无需改码或重新发版，下次冷启动预热后「通过 Google 登录」自动点亮。
- **本地强制点亮联调**：构建时追加 `--dart-define=RC_SOCIAL_PROVIDERS=apple,google`。

---

## 6. 验证与真机安装命令（iPhone 16 Pro）

### 6.1 静态分析与全量单测 / E2E 组件测试

```bash
cd app
flutter analyze && flutter test
```

### 6.2 编译 Release 包并安装到真机（可脱离电脑独立启动）

> iOS 上 Flutter Debug 包脱离 Xcode 调试器后无法从桌面图标直接启动；日常真机体验与随身测试请安装 **Release** 包。

以 `KK's 📱16pro`（iPhone 16 Pro，UDID `00008140-000C4CE23862201C`）为例：

```bash
cd app
# 1. 构建 iOS Release 产物（自动触发 Rust 硬件桥编译）
flutter build ios --release

# 2. 安装到 iPhone 16 Pro 真机
xcrun devicectl device install app \
  --device 00008140-000C4CE23862201C \
  build/ios/iphoneos/Runner.app
```
