# iOS 应用内录音卡快传

2026-11-09 更新。用户点击快传后，App 调起系统「加入无线局域网」确认；同意后直接在 App 内完成临时配件热点文件传输，不要求去设置或手工输入产品默认热点口令。这不是用于上网登录的 captive portal / NEHotspotHelper，而是 Apple 官方推荐的临时 Wi-Fi 配件连接：`NEHotspotConfigurationManager.apply`，配置 `joinOnce = true`。[1] [2]

## 参考代码与默认凭据

参考 `reai_mobile_app/lib/services/recording_sync/hardware_ap_connector.dart:65-80,146-185` 和该项目 `docs/ota/2026-05-19-handoff-wifi-ap-debug.md:80`，产品默认 SSID 是 `DYJ-HD-AP`，默认 WPA 口令是 `reai_dyj_2026`；本项目原生插件仅面向这一个配件默认网络，不提供任意 Wi-Fi 操作能力，不记录口令。

SDK 的 `README.md:241-263` 明确 `WIFI_OPEN` 给 ESP32 上电后启动该 AP 和 `192.168.4.1:80` HTTP 服务，口令仅写「见设备说明」，未给口令值。当前未直接访问到独立固件源码，因此口令的依据是参考 App 两处内容，不宣称所有设备必然一致；最终仍须实际系统加入和 HTTP 就绪确认。

参考 App 的独立网络绑定/loopback 转发只用于 Android；iOS 走 NEHotspotConfiguration 临时连接。iOS 不因设置 joinOnce 就保证原 Wi-Fi 与热点双 Wi-Fi 并行，也不保证手机一定有 Internet。录音卡局域网文件服务无需 Internet：本项目使用固定本地 IP、禁止代理/重定向、不携带 OAuth 凭据。热点期间只做本地转写，新文本云请求由同 session 的实时 localOnly guard 拦住，已有请求在上电前自然排空。结束后再尝试文本润色/总结；联网失败照实呈现。[1]

## 同一会话的数据流

`ServiceDeviceBackend.prepareFastTransfer` 和 AP `CardDownloadAdapter` 共享 `AccessoryHotspotSession`。准备先验证 BLE 设备身份及已停止录音/实时传输，不隐式停录。接着 WIFI_OPEN → 原生 join 系统确认 → 有界探测 `http://192.168.4.1/api/files` 返回 200 且有效 JSON files 数组，之后才准备完成并开始同步。系统 accepted 不是 TCP/HTTP 就绪，也不是 Internet 就绪。

MethodChannel 为 `dev.kongkang.recording-card/hotspot`，`join` 和 `close` 无参数。原生保留结构化 userDenied 与系统错误，不依赖 SSID/定位或把失败压成 false。取消/超时后不从 ACK 释放车道，等待实际 apply final，并清理迟到配置；prepare失败、取消、同步成功/失败统一清理本插件拥有的热点配置与卡上热点。卡端需 read-back `wifiOpen=false`、同设备身份后才归还 SD。清理未确认时继续 busy/localOnly，可以显式重试。

Apple 没有 public 的 apply 取消 API；若 apply 不返回，不能假称取消成功。`removeConfiguration` 为 void，返回只表示移除调用已提交，不证明 RF 已断或 Internet 已恢复。`joinOnce` 连接会在 App 退后台超过15秒、设备休眠、退出等情况下移除，因此真机测试须覆盖这些中断并如实保留完整性失败。[2] [3]

## 签名要求与当前阻断

源码 `Runner.entitlements`、Runner 的 Debug/Release/Profile 接线已经声明 `com.apple.developer.networking.HotspotConfiguration = true`。但 profile 和最终 signed App **两边都必须有实际能力**，不能沿用旧 wildcard profile 硬塞 entitlement。保持原 bundle `dev.kongkang.recordingCard`、原团队 `35N5SGDE59` 和 Keychain access group，覆盖安装不卸载，以保留登录与音频。

2026-11-09 13:24 的 Xcode 实际错误是 `No Accounts: Add a new account in Accounts settings`，以及旧 `iOS Team Provisioning Profile: *` 不含 Hotspot capability/entitlement。用户需要在 Xcode Settings → Accounts 登录可访问原团队的 Developer 账号，然后让当前工作区 Runner 的自动签名生成支持该能力的新 profile。密码、验证码由用户直接输入；不能接受协议或改团队来绕过。

自动签名用 `CODE_SIGN_IDENTITY='Apple Development'`；固定证书 SHA 与 Automatic signing 冲突已经实际触发。允许 provisioning 更新后，仍要检查 profile、signed entitlement、设备登记、原 team/bundle/keychain 和完整签名，再打包安装。遇到不同账号/团队或协议要求，应停止并交接用户。

## 实际验证状态

源码提交 `b3ac7bb`：全量 Flutter analyze 无问题，375 项通过 / 11 项 opt-in 跳过；热点 Native 接线13项静态检查通过。375项包含协作者72项限定回归，不重复计数。110905 的完整 iOS Release/Swift 编译已成功（70.8MB），arm64与四个 C ABI 符号已核验。自动签名目前被上述账户/profile问题拦住，未产生合法的110905可安装包，未覆盖手机。

系统加入、用户拒绝、Local Network 权限、实际 AP HTTP/下载与原文/润色总结闭环，以及后台/休眠恢复仍未验。回环 HTTP 与静态接线不是无线真机成功。普通 BLE 的1200字节短收仍是另一未解决问题；本次没有放宽校验、删除卡源或执行 OTA。

## References

[1]: https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview "Apple TN3111 iOS Wi-Fi API overview"
[2]: https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager "Apple NEHotspotConfigurationManager"
[3]: https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce "Apple joinOnce temporary configuration lifetime"
