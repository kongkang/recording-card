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

## 2. 按钮显隐与就绪矩阵

为避免上线版本出现无法点击的占位入口（App Store 审核 Guideline 2.1），**未配置或服务端未启用的第三方登录入口自动隐藏**；一旦配置正式 `wx...` AppID 或服务端 `/auth/social/providers` 返回对应渠道，登录页自动展示并允许点击：

| 登录入口 | 显示条件（`shouldShow*`） | 可点击条件（`is*Enabled`） | 默认行为（连 `block2-api.wainao.chat`） |
| --- | --- | --- | --- |
| **使用外脑账号登录** | 常驻显示 | `OAuthConfig.isConfigured == true` 且当前无其他登录进行中 | **显示 · 可点击（enabled）** |
| **微信登录** | 已配置合法 `wx...` AppID，且本机未明确缺失微信（`cachedIsInstalled != false`；按 App Store 4.2.3 规范未装微信时隐藏） | `OAuthConfig.isConfigured == true` 且无其他登录进行中 | **配置 `RC_WECHAT_APP_ID=wx...` 后自动展示并可点击；未配置则隐藏** |
| **通过 Apple 登录** | 具备系统安全浏览器能力，且 `/auth/social/providers` 返回含 `"apple"` | `OAuthConfig.isConfigured == true` 且服务端已开启 `apple` | **线上开启 `apple` 时展示 · 可点击；未开启则隐藏** |
| **通过 Google 登录** | 具备系统安全浏览器能力，且 `/auth/social/providers` 返回含 `"google"` | `OAuthConfig.isConfigured == true` 且服务端已开启 `google` | **线上开启 `google` 时展示 · 可点击；未开启则隐藏** |

> **并发与防重入保护**：四个入口共用 `AuthService.activeChannel` 与 `_signInEpoch` 互斥锁——任一入口发起登录期间，该按钮切换为对应 spinner，其余三个按钮全部临时置灰禁点；退出登录或切换账号时旧授权回调自动作废。

---

## 3. 编译期配置参数（`--dart-define`）

| 参数名 | 默认值 | 说明 |
| --- | --- | --- |
| `RC_API_BASE` | `https://block2-api.wainao.chat` | 外脑后端与模型网关根地址 |
| `RC_OAUTH_CLIENT_ID` | `58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo` | OVS OAuth 公共客户端 ID（与 `reai_mobile_app` 共用） |
| `RC_OAUTH_REDIRECT` | `reai-mobile://callback` | OAuth 授权完成回调 URI（已在 iOS `Info.plist` / Android `AndroidManifest.xml` 注册） |
| `RC_WECHAT_APP_ID` | 空（未配置） | 微信开放平台移动应用 `AppID`（必须以 `wx` 开头；兼容回退 `WECHAT_APP_ID`） |
| `RC_WECHAT_UNIVERSAL_LINK` | `https://ai-card.app.reai.com/link/` | 微信登录 Universal Link（须为干净 `https` 地址；需与 `Runner.entitlements` 及微信开放平台保持一致） |
| `RC_SOCIAL_PROVIDERS` | 未定义（走线上 `/auth/social/providers` 探测） | 联调覆盖社会化登录启用列表，例如 `--dart-define=RC_SOCIAL_PROVIDERS=apple,google` |

---

## 4. 微信开放平台启用状态与后续服务端配置

微信开放平台移动应用「录音卡」（`AppID: wx929549126f19f795`，已获「微信登录」能力）审核已通过，客户端已完成如下对齐：

1. **iOS URL Scheme、Universal Link 与编译期配置（已写入）**
   `app/ios/Flutter/Wechat.xcconfig` 已写入正式 `AppID`：
   ```xcconfig
   WECHAT_APP_ID=wx929549126f19f795
   ```
   `app/ios/Runner/Runner.entitlements` 已声明录音卡专属域名 `applinks:ai-card.app.reai.com`，Dart 侧默认 `OAuthConfig.defaultWechatUniversalLink = 'https://ai-card.app.reai.com/link/'`（支持 `--dart-define=RC_WECHAT_UNIVERSAL_LINK=...` 覆盖）。
   > **为什么必须与 `app.cn.reai.com/link/` 隔离**：`app.cn.reai.com` 属于外脑 App（`35N5SGDE59.com.reai.reaiApp`），同一台手机同时安装外脑与录音卡时，iOS 不支持两个 App 共用同一 `applinks` 域名与 `/link/*` 路径（永远只路由给排在前面的已安装 App，导致微信授权回跳时错打开外脑 App）。
   > **不变式**：`Wechat.xcconfig` 中的 `WECHAT_APP_ID` 必须与构建参数 `--dart-define=RC_WECHAT_APP_ID=wx929549126f19f795` 完全一致（`watch/scripts/archive_testflight.sh` 会自动读取并注入），否则微信客户端无法跳回 App。`AppSecret` 仅配置在外脑后端，严禁写入客户端仓库。
2. **上线端到端生效仍需完成的两项外部配置（未完成前 iOS 真机授权会失败或无法回跳）**
   - **部署 `ai-card.app.reai.com` 的 AASA 与 `/link/` 着陆页**：将仓库内 `site/.well-known/apple-app-site-association`、`site/apple-app-site-association`（仅包含 `35N5SGDE59.com.reai.recordingcard` 与 `/link/*`）及 `site/link/index.html` 部署到 `ai-card.app.reai.com`，并确认 Nginx 对 `/.well-known/apple-app-site-association` 与 `/apple-app-site-association` 返回 `HTTP 200` 且 `Content-Type: application/json`（不可回落到 SPA `index.html`）。
   - **微信开放平台更新 Universal Links 与确认后端密钥**：在微信开放平台（`open.weixin.qq.com`，AppID `wx929549126f19f795`）将 iPhone/iPad 的 Universal Links 从 `https://app.cn.reai.com/link/` 修改为 `https://ai-card.app.reai.com/link/`，并确认 `AppSecret` 已配入外脑后端（`block2-api.wainao.chat`）`POST /oauth/token` 微信扩展 grant 映射表。
3. **带参构建或真机安装**
   ```bash
   cd app
   flutter run --release -d 00008140-000C4CE23862201C \
     --dart-define=RC_WECHAT_APP_ID=wx929549126f19f795
   ```
   启动后本机装有微信时，「微信登录」按钮将自动展示并可点击。

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
