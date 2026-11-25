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

## 4. 微信开放平台启用与全链路配置手册（2026-11-25 已上线闭环）

微信开放平台移动应用「录音卡」（`AppID: wx929549126f19f795`，`Bundle ID: com.reai.recordingcard`，与外脑主端 `wxd9ce5b90974d7c2a` 同在开放平台账号 `app@wainao.ai` 下，共享 `unionid`）已获「微信登录」能力并完成 iPhone 真机全链路闭环验证。以下是完整配置与运维手册（后续换域名、轮换密钥或新设备测试直接照此核对）：

1. **客户端配置（已入库）**
   - `app/ios/Flutter/Wechat.xcconfig` 已固定正式 `AppID`：
     ```xcconfig
     WECHAT_APP_ID=wx929549126f19f795
     ```
   - `app/ios/Runner/Runner.entitlements` 声明录音卡专属域名 `applinks:ai-card.app.reai.com`，Dart 侧默认 `OAuthConfig.defaultWechatUniversalLink = 'https://ai-card.app.reai.com/link/'`（支持 `--dart-define=RC_WECHAT_UNIVERSAL_LINK=...` 覆盖）。
   - `OAuthClient.exchangeWechatCodeForToken` 在 `POST https://block2-api.wainao.chat/oauth/token`（`grant_type=urn:wainao:params:oauth:grant-type:wechat`、`app_type=app`）自动携带 `wechat_app_id=wx929549126f19f795`。
   - **为什么必须与 `app.cn.reai.com/link/` 隔离**：`app.cn.reai.com` 属于外脑 App（`35N5SGDE59.com.reai.reaiApp`），同一台手机同时安装外脑与录音卡时，iOS 不支持两个 App 共用同一 `applinks` 域名与 `/link/*` 路径（永远只路由给排在前面的已安装 App，导致微信授权回跳时错打开外脑 App）。
   - **不变式**：`Wechat.xcconfig` 中的 `WECHAT_APP_ID` 必须与构建参数 `--dart-define=RC_WECHAT_APP_ID=wx929549126f19f795` 完全一致（`watch/scripts/archive_testflight.sh` 会自动读取并注入；**手工本地装包也必须显式传递 `--dart-define=RC_WECHAT_APP_ID=wx929549126f19f795`，否则登录页会隐藏微信按钮**）。`AppSecret` 仅配置在外脑后端站点密钥，严禁写入客户端仓库。

2. **域名与 Nginx AASA 配置（`cn.reai.com` / `ai-card.app.reai.com`，已上线）**
   - 服务器目录 `/var/www/ai-card.app.reai.com/` 部署来自仓库 `site/.well-known/apple-app-site-association`、`site/apple-app-site-association` 与 `site/link/index.html`。
   - `/etc/nginx/sites-enabled/ai-card.app.reai.com.conf`（443 server 块、`location /` 之前）显式接管 AASA 与 `/link/`：
     - `location ~ ^/(\.well-known/)?apple-app-site-association$`：返回 `HTTP 200` + `Content-Type: application/json`，内容仅声明 `{"applinks":{"apps":[],"details":[{"appID":"35N5SGDE59.com.reai.recordingcard","paths":["/link/*"]}]}}`（绝不可回落到 SPA `index.html`）。
     - `location ^~ /link/`：返回 `HTTP 200` + `Content-Type: text/html`（`try_files /link/index.html =404;`）。
   - 源站与苹果 CDN 核验命令：
     ```bash
     curl -sSi https://ai-card.app.reai.com/.well-known/apple-app-site-association
     curl -sSi https://app-site-association.cdn-apple.com/a/v1/ai-card.app.reai.com
     ```
     > 注意：若 AASA 域名上线前被探测过 404/HTML，苹果 `cdn-apple.com` 会按 `Cache-Control: max-age=3600` 缓存约 1 小时；必须确认苹果 CDN 返回 `HTTP/1.1 200 OK` + `Content-Type: application/json` 后，真机 Universal Link 才会稳定通过校验。

3. **微信开放平台与外脑后端（`block2-api.wainao.chat`）配置（已上线）**
   - **微信开放平台**（`open.weixin.qq.com`，`wx929549126f19f795`）：iPhone 与 iPad 应用 Bundle ID 均填 `com.reai.recordingcard`，Universal Links 均填 `https://ai-card.app.reai.com/link/`（状态 `已通过`）。
   - **外脑后端加密站点密钥**（不写进 `.env`，无需重启容器）：在 `https://block2.wainao.chat/admin/site-secrets` 中存储密钥 **`WECHAT_LOGIN_MOBILE_SECRET_WX929549126F19F795`**（`wx929549126f19f795` 的 `AppSecret`，AES-GCM 加密存库）。
   - **外脑后端多移动应用路由**（`wainao_editor` PR #2075 / commit `f910ebc56` 已上线）：`POST /oauth/token` 微信 grant 与 `POST /my/wechat/bind` 读取 `wechat_app_id`，未传或传外脑 `wxd9ce5b90974d7c2a` 走原配置；传入 `wx929549126f19f795` 时按 `WECHAT_LOGIN_MOBILE_SECRET_<UPPER_APPID>` 解密路由（缺失 fail-closed 不回落默认凭据）。
   - **账号打通机制**：只要与外脑主端处于同一微信开放平台主体，`unionid` 完全一致，后端按 `(provider='wechat', unionid)` 自动进入原外脑账号（注：若原外脑账号此前仅用邮箱/手机登录且从未绑定微信，需先在原账号绑定微信以免新建独立账号）。

4. **本地真机联调命令 & 常见故障速查**
   ```bash
   cd app
   ./rust/build-ios.sh
   flutter build ios --release --dart-define=RC_WECHAT_APP_ID=wx929549126f19f795
   xcrun devicectl device install app --device 00008140-000C4CE23862201C build/ios/iphoneos/Runner.app
   ```
   - **看不到「微信登录」按钮**：检查是否漏传 `--dart-define=RC_WECHAT_APP_ID=wx929549126f19f795`（例如被另一条未带该参数的 worktree 构建覆盖装机），或本机未安装微信。
   - **授权后跳进外脑 App**：检查微信开放平台 Universal Links 与 `Runner.entitlements` 是否切到 `ai-card.app.reai.com`，且同一台手机上的 AASA 不能包含外脑 Bundle ID。
   - **回跳后页面提示「登录已过期，请重新登录」**：客户端把后端 OAuth 错误 `invalid_grant` 映射为此文案，**并非时间问题**；常见根因是微信开放平台 `AppSecret` 未生成/重置未同步，或 `block2.wainao.chat/admin/site-secrets` 中缺少/写错了 `WECHAT_LOGIN_MOBILE_SECRET_WX929549126F19F795`（服务端日志表现为 `wechat access_token 微信错误 errcode=40029 errmsg=invalid code`）。
   - **刚改好 AASA 仍无法回跳**：确认 `app-site-association.cdn-apple.com` 是否还在 3600s 边缘 404 缓存期内；等刷新后重装 App 验证。

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
# 1. 新建 worktree 如缺 libcard_bridge.a，先编译 Rust iOS 硬件桥
./rust/build-ios.sh

# 2. 构建 iOS Release 产物（必须携带 RC_WECHAT_APP_ID 才会点亮「微信登录」按钮）
flutter build ios --release --dart-define=RC_WECHAT_APP_ID=wx929549126f19f795

# 3. 安装到 iPhone 16 Pro 真机
xcrun devicectl device install app \
  --device 00008140-000C4CE23862201C \
  build/ios/iphoneos/Runner.app
```
