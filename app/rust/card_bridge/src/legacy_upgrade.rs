//! 旧版固件独立引导升级模块（与正常设备 `ACTIVE_DEVICE` 状态机完全解耦）。
//!
//! 当某款硬件因固件版本过低无法走当前主协议连接时，通过独立生命周期会话完成：
//! 1. 以兼容旧协议建立控制通道（对 `dyj_v1` `< 0.8.0` 仅订阅 `FF11`，绝不碰无 Notify 的 `FF12`）；
//! 2. 查询设备版本号与当前 Wi-Fi 状态、扫描附近 Wi-Fi；
//! 3. 下发 Wi-Fi 凭据并等待真实联网成功（含对旧固件空密码覆盖风险的保护）；
//! 4. 触发设备下载安装新固件，监听下载/安装进度与覆盖安装预期断连；
//! 5. 等待设备重启自拉起并校验新协议特征就绪后，释放会话供上层自动重连蓝牙。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use btleplug::api::{Central as _, CharPropFlags, Characteristic, Peripheral as _, ScanFilter, WriteType};
use btleplug::platform::{Adapter, Peripheral};
use futures::stream::StreamExt;
use serde_json::{json, Value};
use tokio::sync::{broadcast, Mutex as AsyncMutex};

use crate::dyj_v1_session::{parse_legacy_version_from_line, COMMAND_UUID, DATA_UUID};
use crate::BridgeError;

const LEGACY_TARGET_VERSION: &str = "0.8.15";
const LEGACY_TARGET_API_BASE: &str = "https://hdd.dev.reai.com/api";
const LEGACY_TARGET_OTA_INFO_URL: &str = "https://hdd.dev.reai.com/api/ota/info?mod=app";
const GATT_OP_TIMEOUT: Duration = Duration::from_secs(6);
const NOTIFY_SETTLE: Duration = Duration::from_millis(1200);

#[derive(Clone)]
enum LegacyUpgradeDriver {
    DyjV1(Arc<DyjV1LegacyUpgradeSession>),
}

impl LegacyUpgradeDriver {
    async fn scan_wifi(&self) -> Result<Value, BridgeError> {
        match self {
            Self::DyjV1(sess) => sess.scan_wifi().await,
        }
    }

    async fn connect_wifi(&self, ssid: &str, password: Option<&str>) -> Result<Value, BridgeError> {
        match self {
            Self::DyjV1(sess) => sess.connect_wifi(ssid, password).await,
        }
    }

    async fn run_ota(&self, emit: &(dyn Fn(Value) + Send + Sync)) -> Result<Value, BridgeError> {
        match self {
            Self::DyjV1(sess) => sess.run_ota(emit).await,
        }
    }

    async fn close(&self) {
        match self {
            Self::DyjV1(sess) => sess.close().await,
        }
    }
}

static LEGACY_UPGRADE_SESSION: OnceLock<AsyncMutex<Option<LegacyUpgradeDriver>>> = OnceLock::new();

fn session_slot() -> &'static AsyncMutex<Option<LegacyUpgradeDriver>> {
    LEGACY_UPGRADE_SESSION.get_or_init(|| AsyncMutex::new(None))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedLegacyLine {
    pub command: String,
    pub payload: Value,
}

/// 解析旧版固件（`v0.7.x`）按 `<COMMAND>:<JSON>` 回传的单行响应。
pub fn parse_legacy_response_line(line: &str) -> Option<ParsedLegacyLine> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    let (cmd, rest) = trimmed.split_once(':')?;
    let command = cmd.trim();
    if command.is_empty() {
        return None;
    }
    let payload: Value = serde_json::from_str(rest.trim()).ok()?;
    Some(ParsedLegacyLine {
        command: command.to_string(),
        payload,
    })
}

/// 判断旧固件的 Wi-Fi 安全能力串是否需要密码。
pub fn is_legacy_capabilities_secured(capabilities: &str) -> bool {
    let upper = capabilities.to_ascii_uppercase();
    upper.contains("WPA") || upper.contains("WEP") || upper.contains("SAE") || upper.contains("RSN")
}

/// 防止对旧固件发出空密码 `WIFI_CONNECT`：
/// `dyj-app-v2` `NetworkManager.connectWifi` 在 `password` 为空时会删除已有同名配置并改为开放网络，
/// 若设备当前已经连着同名 Wi-Fi 且拿到有效 IP，应直接复用而不覆写密码配置。
pub fn can_reuse_existing_wifi(
    status: &Value,
    target_ssid: &str,
    supplied_password: Option<&str>,
) -> Option<String> {
    if supplied_password.is_some_and(|p| !p.is_empty()) {
        return None;
    }
    let connected = status.get("connected").and_then(Value::as_bool) == Some(true);
    let current_ssid = status
        .get("ssid")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    let ip = status
        .get("ipAddress")
        .or_else(|| status.get("ip"))
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    if connected && current_ssid == target_ssid.trim() && !ip.is_empty() {
        Some(ip.to_string())
    } else {
        None
    }
}

/// 将 `OTA_UPDATE` 下载百分比（0..100）线性映射为引导升级 UI 百分比（5..78）。
pub fn map_ota_download_percent(raw_pct: u64) -> u8 {
    let clamped = raw_pct.min(100);
    (5 + (clamped * 73) / 100) as u8
}

/// 目标新版本 OTA 清单兜底 URL，供升上 `0.8.x` 后校准远端检查来源。
pub fn default_target_ota_info_url() -> &'static str {
    LEGACY_TARGET_OTA_INFO_URL
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LegacyWifiNetwork {
    pub ssid: String,
    pub rssi: i64,
    pub secure: bool,
    pub connected: bool,
}

/// 从 `WIFI_SCAN` 原始响应切片中去重并按信号强弱降序排序。
pub fn aggregate_legacy_wifi_networks(items: &[Value], current_ssid: Option<&str>) -> Value {
    let mut best_by_ssid: HashMap<String, LegacyWifiNetwork> = HashMap::new();
    let active_ssid = current_ssid.map(str::trim).filter(|s| !s.is_empty());

    for item in items {
        let idx = item.get("index").and_then(Value::as_i64).unwrap_or(0);
        if idx < 0 {
            continue;
        }
        let ssid = item
            .get("ssid")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        if ssid.is_empty() {
            continue;
        }
        let rssi = item.get("level").and_then(Value::as_i64).unwrap_or(-90);
        let caps = item
            .get("capabilities")
            .and_then(Value::as_str)
            .unwrap_or("");
        let secure = is_legacy_capabilities_secured(caps);
        let connected = active_ssid == Some(ssid);
        let entry = LegacyWifiNetwork {
            ssid: ssid.to_string(),
            rssi,
            secure,
            connected,
        };
        best_by_ssid
            .entry(ssid.to_string())
            .and_modify(|prev| {
                if entry.rssi > prev.rssi {
                    *prev = entry.clone();
                }
            })
            .or_insert(entry);
    }

    let mut list: Vec<LegacyWifiNetwork> = best_by_ssid.into_values().collect();
    list.sort_by(|a, b| {
        b.connected
            .cmp(&a.connected)
            .then_with(|| b.rssi.cmp(&a.rssi))
            .then_with(|| a.ssid.cmp(&b.ssid))
    });

    let networks: Vec<Value> = list
        .into_iter()
        .map(|n| {
            json!({
                "ssid": n.ssid,
                "rssi": n.rssi,
                "secure": n.secure,
                "connected": n.connected,
            })
        })
        .collect();

    json!({
        "networks": networks,
        "currentSsid": active_ssid,
    })
}

pub struct DyjV1LegacyUpgradeSession {
    adapter: Adapter,
    device_id: String,
    device_name: String,
    peripheral: Peripheral,
    cmd_char: Characteristic,
    cmd_lock: AsyncMutex<()>,
    line_tx: broadcast::Sender<Result<ParsedLegacyLine, String>>,
    disconnected: Arc<AtomicBool>,
}

impl DyjV1LegacyUpgradeSession {
    async fn resolve_peripheral(
        adapter: &Adapter,
        id_hint: &str,
        name_hint: &str,
    ) -> Result<Peripheral, BridgeError> {
        let trimmed_name = name_hint.trim();
        if let Some(p) = find_in_adapter(adapter, id_hint, trimmed_name).await {
            return Ok(p);
        }

        let _ = adapter.start_scan(ScanFilter::default()).await;
        let mut found = None;
        for _ in 0..8 {
            tokio::time::sleep(Duration::from_millis(800)).await;
            if let Some(p) = find_in_adapter(adapter, id_hint, trimmed_name).await {
                found = Some(p);
                break;
            }
        }
        let _ = adapter.stop_scan().await;
        found.ok_or_else(|| {
            BridgeError::from(format!(
                "未在附近找到点一机 V1（{name_hint}），请确认设备已开机且在手机附近"
            ))
        })
    }

    pub(crate) async fn connect_open(
        adapter: &Adapter,
        id_hint: &str,
        name_hint: &str,
    ) -> Result<(Arc<Self>, Value), BridgeError> {
        let peripheral = Self::resolve_peripheral(adapter, id_hint, name_hint).await?;
        let actual_id = peripheral.id().to_string();

        match tokio::time::timeout(Duration::from_secs(12), peripheral.connect()).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                return Err(BridgeError::from(format!(
                    "连接点一机旧固件通道失败：{e}"
                )));
            }
            Err(_) => {
                let _ = tokio::time::timeout(Duration::from_secs(2), peripheral.disconnect()).await;
                return Err(BridgeError::from(
                    "连接点一机旧固件通道超时，请重试".to_string(),
                ));
            }
        }

        if !matches!(
            tokio::time::timeout(Duration::from_secs(8), peripheral.discover_services()).await,
            Ok(Ok(()))
        ) {
            let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
            return Err(BridgeError::from(
                "点一机旧固件服务发现失败，请重试".to_string(),
            ));
        }

        let chars = peripheral.characteristics();
        let cmd_char = chars
            .iter()
            .find(|c| c.uuid.to_string().eq_ignore_ascii_case(COMMAND_UUID))
            .cloned()
            .ok_or_else(|| {
                BridgeError::from("未找到点一机控制特征 (FF11)".to_string())
            })?;
        if !cmd_char.properties.contains(CharPropFlags::NOTIFY) {
            let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
            return Err(BridgeError::from(
                "点一机控制特征 (FF11) 不支持通知".to_string(),
            ));
        }

        // 只订阅 FF11（v0.7.x 的 FF12 无 Notify/2902 CCCD）
        match tokio::time::timeout(GATT_OP_TIMEOUT, peripheral.subscribe(&cmd_char)).await {
            Ok(Ok(())) => {}
            _ => {
                let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
                return Err(BridgeError::from(
                    "订阅点一机控制通道 (FF11) 失败，请重试".to_string(),
                ));
            }
        }

        tokio::time::sleep(NOTIFY_SETTLE).await;

        let notifications = match tokio::time::timeout(Duration::from_secs(5), peripheral.notifications()).await {
            Ok(Ok(s)) => s,
            _ => {
                let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
                return Err(BridgeError::from(
                    "建立点一机通知监听失败，请重试".to_string(),
                ));
            }
        };

        let (line_tx, _) = broadcast::channel::<Result<ParsedLegacyLine, String>>(128);
        let disconnected = Arc::new(AtomicBool::new(false));
        let tx_clone = line_tx.clone();
        let disc_clone = disconnected.clone();
        let peripheral_watch = peripheral.clone();

        tokio::spawn(async move {
            let mut stream = notifications;
            let mut raw_buf: Vec<u8> = Vec::with_capacity(1024);
            loop {
                let next_note = tokio::time::timeout(Duration::from_secs(2), stream.next()).await;
                match next_note {
                    Ok(Some(note)) => {
                        if raw_buf.is_empty() && note.value.first() == Some(&0x00) {
                            continue;
                        }
                        raw_buf.extend_from_slice(&note.value);
                        while let Some(pos) = raw_buf.iter().position(|&b| b == b'\n') {
                            let mut line_bytes: Vec<u8> = raw_buf.drain(..=pos).collect();
                            while matches!(line_bytes.last(), Some(b'\n' | b'\r')) {
                                line_bytes.pop();
                            }
                            if line_bytes.first() == Some(&0x00) || line_bytes.is_empty() {
                                continue;
                            }
                            let line = String::from_utf8_lossy(&line_bytes);
                            if let Some(parsed) = parse_legacy_response_line(&line) {
                                let _ = tx_clone.send(Ok(parsed));
                            }
                        }
                        if raw_buf.len() > 64 * 1024 {
                            raw_buf.clear();
                        }
                    }
                    Ok(None) => {
                        disc_clone.store(true, Ordering::SeqCst);
                        let _ = tx_clone.send(Err("disconnected".to_string()));
                        break;
                    }
                    Err(_) => {
                        if matches!(peripheral_watch.is_connected().await, Ok(false)) {
                            disc_clone.store(true, Ordering::SeqCst);
                            let _ = tx_clone.send(Err("disconnected".to_string()));
                            break;
                        }
                    }
                }
            }
        });

        let session = Arc::new(Self {
            adapter: adapter.clone(),
            device_id: actual_id.clone(),
            device_name: name_hint.trim().to_string(),
            peripheral,
            cmd_char,
            cmd_lock: AsyncMutex::new(()),
            line_tx,
            disconnected,
        });

        let base_info = session.request_single("BASE_INFO", None, Duration::from_secs(5)).await?;
        let current_ver = base_info
            .get("version")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .or_else(|| parse_legacy_version_from_line(&base_info.to_string()))
            .unwrap_or_else(|| "0.7.2".to_string());
        let resolved_name = base_info
            .get("deviceName")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(&session.device_name)
            .to_string();

        let mut wifi_st = session
            .request_single("WIFI_STATUS", None, Duration::from_secs(5))
            .await
            .unwrap_or_else(|_| json!({"enabled": false, "connected": false}));
        if wifi_st.get("enabled").and_then(Value::as_bool) != Some(true) {
            let _ = session
                .request_single("WIFI_ENABLE", Some(&json!({"enabled": true})), Duration::from_secs(5))
                .await;
            tokio::time::sleep(Duration::from_millis(1200)).await;
            wifi_st = session
                .request_single("WIFI_STATUS", None, Duration::from_secs(5))
                .await
                .unwrap_or(wifi_st);
        }

        let wifi_enabled = wifi_st.get("enabled").and_then(Value::as_bool).unwrap_or(false);
        let wifi_connected = wifi_st.get("connected").and_then(Value::as_bool) == Some(true);
        let current_ssid = wifi_st
            .get("ssid")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);

        let info = json!({
            "deviceId": actual_id,
            "name": resolved_name,
            "deviceKind": "dyj_v1",
            "currentVersion": current_ver,
            "targetVersion": LEGACY_TARGET_VERSION,
            "wifiEnabled": wifi_enabled,
            "wifiConnected": wifi_connected,
            "currentSsid": current_ssid,
        });

        Ok((session, info))
    }

    async fn write_command(&self, cmd: &str, params: Option<&Value>) -> Result<(), BridgeError> {
        if self.disconnected.load(Ordering::SeqCst) {
            return Err(BridgeError::from("与点一机的蓝牙连接已断开".to_string()));
        }
        let line = match params {
            Some(v) => format!("{cmd}:{}\r\n", v),
            None => format!("{cmd}\r\n"),
        };
        let write_type = if self.cmd_char.properties.contains(CharPropFlags::WRITE) {
            WriteType::WithResponse
        } else {
            WriteType::WithoutResponse
        };
        tokio::time::timeout(
            Duration::from_secs(4),
            self.peripheral.write(&self.cmd_char, line.as_bytes(), write_type),
        )
        .await
        .map_err(|_| BridgeError::from(format!("向点一机写入命令 {cmd} 超时")))?
        .map_err(|e| BridgeError::from(format!("向点一机写入命令 {cmd} 失败：{e}")))
    }

    async fn request_single(
        &self,
        cmd: &str,
        params: Option<&Value>,
        timeout: Duration,
    ) -> Result<Value, BridgeError> {
        let _guard = self.cmd_lock.lock().await;
        let mut rx = self.line_tx.subscribe();
        self.write_command(cmd, params).await?;
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
            if rem.is_zero() {
                return Err(BridgeError::from(format!("等待点一机响应 {cmd} 超时")));
            }
            match tokio::time::timeout(rem, rx.recv()).await {
                Ok(Ok(Ok(parsed))) if parsed.command == cmd => return Ok(parsed.payload),
                Ok(Ok(Ok(_))) => continue,
                Ok(Ok(Err(_))) => return Err(BridgeError::from("与点一机的蓝牙连接已断开".to_string())),
                Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(_)) => return Err(BridgeError::from("点一机控制通道已关闭".to_string())),
                Err(_) => return Err(BridgeError::from(format!("等待点一机响应 {cmd} 超时"))),
            }
        }
    }

    pub(crate) async fn scan_wifi(&self) -> Result<Value, BridgeError> {
        let status = self
            .request_single("WIFI_STATUS", None, Duration::from_secs(5))
            .await
            .unwrap_or_else(|_| json!({}));
        if status.get("enabled").and_then(Value::as_bool) != Some(true) {
            let _ = self
                .request_single(
                    "WIFI_ENABLE",
                    Some(&json!({"enabled": true})),
                    Duration::from_secs(5),
                )
                .await?;
            tokio::time::sleep(Duration::from_millis(1200)).await;
        }

        let current_ssid = if status.get("connected").and_then(Value::as_bool) == Some(true) {
            status
                .get("ssid")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        } else {
            None
        };

        let _guard = self.cmd_lock.lock().await;
        let mut rx = self.line_tx.subscribe();
        self.write_command("WIFI_SCAN", None).await?;

        let mut items = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(16);
        loop {
            let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
            if rem.is_zero() {
                break;
            }
            match tokio::time::timeout(rem, rx.recv()).await {
                Ok(Ok(Ok(parsed))) if parsed.command == "WIFI_SCAN" => {
                    let code = parsed.payload.get("code").and_then(Value::as_i64).unwrap_or(0);
                    if code != 0 {
                        let msg = parsed
                            .payload
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("扫描 Wi-Fi 失败");
                        return Err(BridgeError::from(msg.to_string()));
                    }
                    let idx = parsed
                        .payload
                        .get("index")
                        .and_then(Value::as_i64)
                        .unwrap_or(-1);
                    if idx < 0 {
                        break;
                    }
                    items.push(parsed.payload);
                }
                Ok(Ok(Ok(_))) => continue,
                Ok(Ok(Err(_))) => return Err(BridgeError::from("与点一机的蓝牙连接已断开".to_string())),
                Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(_)) => break,
                Err(_) => break,
            }
        }

        Ok(aggregate_legacy_wifi_networks(&items, current_ssid.as_deref()))
    }

    pub(crate) async fn connect_wifi(&self, ssid: &str, password: Option<&str>) -> Result<Value, BridgeError> {
        let target_ssid = ssid.trim();
        if target_ssid.is_empty() {
            return Err(BridgeError::from("请选择要连接的 Wi-Fi 网络".to_string()));
        }

        let initial_status = self
            .request_single("WIFI_STATUS", None, Duration::from_secs(5))
            .await
            .unwrap_or_else(|_| json!({}));

        if let Some(ip) = can_reuse_existing_wifi(&initial_status, target_ssid, password) {
            return Ok(json!({
                "connected": true,
                "ssid": target_ssid,
                "ip": ip,
            }));
        }

        if initial_status.get("enabled").and_then(Value::as_bool) != Some(true) {
            let _ = self
                .request_single(
                    "WIFI_ENABLE",
                    Some(&json!({"enabled": true})),
                    Duration::from_secs(5),
                )
                .await?;
            tokio::time::sleep(Duration::from_millis(1200)).await;
        }

        let mut params = serde_json::Map::new();
        params.insert("ssid".into(), json!(target_ssid));
        if let Some(pwd) = password.filter(|p| !p.is_empty()) {
            params.insert("password".into(), json!(pwd));
        }

        let resp = self
            .request_single("WIFI_CONNECT", Some(&Value::Object(params)), Duration::from_secs(8))
            .await?;
        let code = resp.get("code").and_then(Value::as_i64).unwrap_or(0);
        if code != 0 {
            let msg = resp
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("发送 Wi-Fi 连接命令失败");
            return Err(BridgeError::from(msg.to_string()));
        }

        // v0.7.2 NetworkManager.connectWifi 会先 disconnect 再 reconnect，等 1.5s 再开始轮询状态避免误判旧连接
        tokio::time::sleep(Duration::from_millis(1500)).await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(22);
        while tokio::time::Instant::now() < deadline {
            if let Ok(st) = self
                .request_single("WIFI_STATUS", None, Duration::from_secs(5))
                .await
            {
                let connected = st.get("connected").and_then(Value::as_bool) == Some(true);
                let cur_ssid = st.get("ssid").and_then(Value::as_str).map(str::trim).unwrap_or("");
                let ip = st.get("ipAddress").and_then(Value::as_str).map(str::trim).unwrap_or("");
                if connected && cur_ssid == target_ssid && !ip.is_empty() {
                    return Ok(json!({
                        "connected": true,
                        "ssid": target_ssid,
                        "ip": ip,
                    }));
                }
            }
            tokio::time::sleep(Duration::from_millis(1500)).await;
        }

        Err(BridgeError::from(
            "Wi-Fi 连接未成功，请核对密码是否为 2.4GHz 网络密码后重试".to_string(),
        ))
    }

    pub(crate) async fn run_ota(&self, emit: &(dyn Fn(Value) + Send + Sync)) -> Result<Value, BridgeError> {
        emit(json!({
            "stage": "checking",
            "percent": 2,
            "text": "正在确认新版固件版本…",
        }));

        // 兼容含 2026-06-13 抗砖改址命令的 v0.7.x 固件；若返回 -1001 未知命令则静默忽略
        let _ = self
            .request_single(
                "ENDPOINT_SET",
                Some(&json!({"api": LEGACY_TARGET_API_BASE})),
                Duration::from_secs(3),
            )
            .await;

        let check = self
            .request_single("OTA_CHECK", None, Duration::from_secs(20))
            .await?;
        let chk_code = check.get("code").and_then(Value::as_i64).unwrap_or(0);
        if chk_code != 0 {
            let msg = check
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("检查新版本失败，请确认当前 Wi-Fi 可正常访问外网");
            return Err(BridgeError::from(msg.to_string()));
        }

        let need_update = check.get("needUpdate").and_then(Value::as_bool).unwrap_or(false);
        let remote_ver = check
            .get("remoteVersion")
            .and_then(|v| v.get("versionName"))
            .and_then(Value::as_str)
            .unwrap_or(LEGACY_TARGET_VERSION)
            .to_string();

        if !need_update {
            return Err(BridgeError::from(
                "远端清单未返回更高版本固件，暂时无法升级".to_string(),
            ));
        }

        {
            emit(json!({
                "stage": "downloading",
                "percent": 4,
                "text": "正在下载新固件 0%…",
                "version": remote_ver,
            }));

            let mut max_dl_pct = 0u64;
            let mut entered_installing = false;
            let mut ota_error: Option<String> = None;

            {
                let _guard = self.cmd_lock.lock().await;
                let mut rx = self.line_tx.subscribe();
                self.write_command("OTA_UPDATE", None).await?;

                let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
                let mut install_deadline: Option<tokio::time::Instant> = None;
                loop {
                    let effective_deadline = match install_deadline {
                        Some(id) if id < deadline => id,
                        _ => deadline,
                    };
                    let rem = effective_deadline.saturating_duration_since(tokio::time::Instant::now());
                    if rem.is_zero() {
                        if entered_installing {
                            break;
                        }
                        return Err(BridgeError::from(
                            "固件下载或安装超时，请保持设备供电与 Wi-Fi 畅通后重试".to_string(),
                        ));
                    }

                    match tokio::time::timeout(rem, rx.recv()).await {
                        Ok(Ok(Ok(parsed))) if parsed.command == "OTA_UPDATE" => {
                            let code = parsed.payload.get("code").and_then(Value::as_i64).unwrap_or(0);
                            if code != 0 {
                                let msg = parsed
                                    .payload
                                    .get("message")
                                    .and_then(Value::as_str)
                                    .unwrap_or("升级失败");
                                ota_error = Some(msg.to_string());
                                break;
                            }
                            let state = parsed
                                .payload
                                .get("state")
                                .and_then(Value::as_str)
                                .unwrap_or("");
                            match state {
                                "DOWNLOADING" => {
                                    let raw_pct = parsed
                                        .payload
                                        .get("progress")
                                        .and_then(Value::as_u64)
                                        .unwrap_or(0);
                                    if raw_pct > max_dl_pct {
                                        max_dl_pct = raw_pct;
                                    }
                                    let mapped = map_ota_download_percent(max_dl_pct);
                                    emit(json!({
                                        "stage": "downloading",
                                        "percent": mapped,
                                        "text": format!("正在下载新固件 {}%…", max_dl_pct.min(100)),
                                        "version": remote_ver,
                                    }));
                                }
                                "INSTALLING" => {
                                    entered_installing = true;
                                    install_deadline.get_or_insert_with(|| {
                                        tokio::time::Instant::now() + Duration::from_secs(45)
                                    });
                                    emit(json!({
                                        "stage": "installing",
                                        "percent": 84,
                                        "text": "下载完成，正在静默安装新固件…",
                                        "version": remote_ver,
                                    }));
                                }
                                "SUCCESS" => {
                                    if !entered_installing {
                                        emit(json!({
                                            "stage": "installing",
                                            "percent": 86,
                                            "text": "安装完成，正在重启点一机…",
                                            "version": remote_ver,
                                        }));
                                    }
                                    break;
                                }
                                "FAILED" => {
                                    let msg = parsed
                                        .payload
                                        .get("message")
                                        .and_then(Value::as_str)
                                        .unwrap_or("新固件下载或安装失败");
                                    ota_error = Some(msg.to_string());
                                    break;
                                }
                                _ => {}
                            }
                        }
                        Ok(Ok(Ok(_))) => continue,
                        Ok(Ok(Err(_))) => {
                            if entered_installing || max_dl_pct >= 95 {
                                break;
                            }
                            ota_error = Some("升级过程中点一机蓝牙意外断开，请确认电量后重试".to_string());
                            break;
                        }
                        Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                        Ok(Err(_)) => {
                            if entered_installing || max_dl_pct >= 95 {
                                break;
                            }
                            ota_error = Some("升级状态通道意外关闭".to_string());
                            break;
                        }
                        Err(_) => {
                            if entered_installing {
                                break;
                            }
                            ota_error = Some("固件下载超时，请重试".to_string());
                            break;
                        }
                    }
                }
            }

            if let Some(err) = ota_error {
                return Err(BridgeError::from(err));
            }
        }

        // 释放旧进程 GATT 句柄，等待 pm install 收尾及 persistent 自拉起 0.8.15
        self.close().await;
        emit(json!({
            "stage": "rebooting",
            "percent": 90,
            "text": "安装完成，正在等待点一机重启并恢复蓝牙广播…",
            "version": remote_ver,
        }));

        tokio::time::sleep(Duration::from_secs(6)).await;

        let scan_deadline = Instant::now() + Duration::from_secs(75);
        while Instant::now() < scan_deadline {
            if let Some((found_id, found_name, p)) =
                Self::scan_for_restarted_device(&self.adapter, &self.device_id, &self.device_name)
                    .await
            {
                let upgraded = Self::probe_upgraded_ff12_notify(&p).await;
                let _ = tokio::time::timeout(Duration::from_secs(3), p.disconnect()).await;
                tokio::time::sleep(Duration::from_millis(1200)).await;
                if upgraded {
                    emit(json!({
                        "stage": "done",
                        "percent": 100,
                        "text": "点一机已升级就绪，正在自动连接蓝牙…",
                        "version": remote_ver,
                    }));
                    return Ok(json!({
                        "ok": true,
                        "deviceId": found_id,
                        "name": found_name,
                        "targetVersion": remote_ver,
                    }));
                }
            }
            tokio::time::sleep(Duration::from_millis(1500)).await;
        }

        Err(BridgeError::from(
            "点一机安装完成但等待新版蓝牙恢复超时，请返回列表重新扫描连接".to_string(),
        ))
    }

    async fn scan_for_restarted_device(
        adapter: &Adapter,
        orig_id: &str,
        expected_name: &str,
    ) -> Option<(String, String, Peripheral)> {
        let _ = adapter.start_scan(ScanFilter::default()).await;
        let deadline = Instant::now() + Duration::from_secs(4);
        let mut match_found = None;
        while Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(700)).await;
            if let Some(p) = find_in_adapter(adapter, orig_id, expected_name).await {
                let id = p.id().to_string();
                let name = read_peripheral_name(&p)
                    .await
                    .unwrap_or_else(|| expected_name.to_string());
                match_found = Some((id, name, p));
                break;
            }
        }
        let _ = adapter.stop_scan().await;
        match_found
    }

    async fn probe_upgraded_ff12_notify(peripheral: &Peripheral) -> bool {
        if !matches!(
            tokio::time::timeout(Duration::from_secs(8), peripheral.connect()).await,
            Ok(Ok(()))
        ) {
            return false;
        }
        if !matches!(
            tokio::time::timeout(Duration::from_secs(6), peripheral.discover_services()).await,
            Ok(Ok(()))
        ) {
            return false;
        }
        let has_notify = peripheral.characteristics().iter().any(|c| {
            c.uuid.to_string().eq_ignore_ascii_case(DATA_UUID)
                && c.properties.contains(CharPropFlags::NOTIFY)
        });
        has_notify
    }

    pub async fn close(&self) {
        self.disconnected.store(true, Ordering::SeqCst);
        let _ = tokio::time::timeout(Duration::from_secs(3), self.peripheral.disconnect()).await;
    }
}

async fn read_peripheral_name(p: &Peripheral) -> Option<String> {
    let props = tokio::time::timeout(Duration::from_millis(350), p.properties())
        .await
        .ok()
        .and_then(Result::ok)
        .flatten()?;
    props
        .local_name
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

async fn find_in_adapter(adapter: &Adapter, id_hint: &str, trimmed_name: &str) -> Option<Peripheral> {
    let peripherals = adapter.peripherals().await.ok()?;
    if !trimmed_name.is_empty() {
        for p in &peripherals {
            if let Some(local) = read_peripheral_name(p).await {
                if local == trimmed_name {
                    return Some(p.clone());
                }
            }
        }
    }
    if !id_hint.is_empty() {
        if let Some(exact) = peripherals.iter().find(|p| p.id().to_string() == id_hint) {
            return Some(exact.clone());
        }
    }
    None
}

// ── 外部桥命令入口（与正常连接通道隔离） ────────────────────────────

pub(crate) async fn open_session(adapter: &Adapter, payload: &Value) -> Result<Value, BridgeError> {
    close_session().await;

    let device_kind = payload
        .get("deviceKind")
        .and_then(Value::as_str)
        .unwrap_or("dyj_v1");
    let id = payload
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("");
    let name = payload
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("");

    match device_kind {
        "dyj_v1" => {
            let (sess, info) = DyjV1LegacyUpgradeSession::connect_open(adapter, id, name).await?;
            *session_slot().lock().await = Some(LegacyUpgradeDriver::DyjV1(sess));
            Ok(info)
        }
        other => Err(BridgeError::from(format!(
            "硬件类型 {other} 暂不支持旧固件引导升级"
        ))),
    }
}

pub(crate) async fn scan_wifi() -> Result<Value, BridgeError> {
    let driver = session_slot()
        .lock()
        .await
        .clone()
        .ok_or_else(|| BridgeError::from("旧固件升级会话未打开".to_string()))?;
    driver.scan_wifi().await
}

pub(crate) async fn connect_wifi(payload: &Value) -> Result<Value, BridgeError> {
    let ssid = payload
        .get("ssid")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let password = payload
        .get("password")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    let driver = session_slot()
        .lock()
        .await
        .clone()
        .ok_or_else(|| BridgeError::from("旧固件升级会话未打开".to_string()))?;
    driver.connect_wifi(&ssid, password.as_deref()).await
}

pub(crate) async fn run_ota(emit: &(dyn Fn(Value) + Send + Sync)) -> Result<Value, BridgeError> {
    let driver = session_slot()
        .lock()
        .await
        .clone()
        .ok_or_else(|| BridgeError::from("旧固件升级会话未打开".to_string()))?;
    let res = driver.run_ota(emit).await;
    // 不论成功或失败，OTA 收尾后都清空独立升级会话，避免残留旧 BLE 句柄
    close_session().await;
    res
}

pub(crate) async fn close_session() -> Value {
    let old = session_slot().lock().await.take();
    if let Some(driver) = old {
        driver.close().await;
    }
    json!({"closed": true})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_legacy_response_lines() {
        let base = parse_legacy_response_line(
            r#"BASE_INFO:{"code":0,"version":"0.7.2","versionCode":702,"deviceName":"DYJ_Q2M34R"}"#,
        )
        .unwrap();
        assert_eq!(base.command, "BASE_INFO");
        assert_eq!(base.payload["version"], "0.7.2");

        let ota = parse_legacy_response_line(
            r#"OTA_UPDATE:{"code":0,"message":"OTA_PROCESS","state":"DOWNLOADING","progress":45}"#,
        )
        .unwrap();
        assert_eq!(ota.command, "OTA_UPDATE");
        assert_eq!(ota.payload["state"], "DOWNLOADING");
        assert_eq!(ota.payload["progress"], 45);
        assert!(parse_legacy_response_line("\x00\x01\x02").is_none());
    }

    #[test]
    fn guards_empty_password_on_already_connected_ssid() {
        let status = json!({
            "enabled": true,
            "connected": true,
            "ssid": "CloudOS.com",
            "ipAddress": "192.168.31.57"
        });
        assert_eq!(
            can_reuse_existing_wifi(&status, "CloudOS.com", None),
            Some("192.168.31.57".to_string())
        );
        assert_eq!(
            can_reuse_existing_wifi(&status, "CloudOS.com", Some("")),
            Some("192.168.31.57".to_string())
        );
        assert_eq!(
            can_reuse_existing_wifi(&status, "CloudOS.com", Some("18503056146")),
            None
        );
        assert_eq!(can_reuse_existing_wifi(&status, "OtherNet", None), None);
    }

    #[test]
    fn aggregates_and_sorts_legacy_wifi_scan_items() {
        let items = vec![
            json!({"index": 0, "ssid": "Guest", "level": -82, "capabilities": "[ESS]"}),
            json!({"index": 1, "ssid": "CloudOS.com", "level": -61, "capabilities": "[WPA2-PSK-CCMP][ESS]"}),
            json!({"index": 2, "ssid": "CloudOS.com", "level": -45, "capabilities": "[WPA2-PSK-CCMP][ESS]"}),
            json!({"index": 3, "ssid": "", "level": -40, "capabilities": "[WPA2]"}),
        ];
        let out = aggregate_legacy_wifi_networks(&items, Some("CloudOS.com"));
        let nets = out["networks"].as_array().unwrap();
        assert_eq!(nets.len(), 2);
        assert_eq!(nets[0]["ssid"], "CloudOS.com");
        assert_eq!(nets[0]["rssi"], -45);
        assert_eq!(nets[0]["secure"], true);
        assert_eq!(nets[0]["connected"], true);
        assert_eq!(nets[1]["ssid"], "Guest");
        assert_eq!(nets[1]["secure"], false);
        assert_eq!(nets[1]["connected"], false);
    }

    #[test]
    fn maps_ota_download_percent_monotonically() {
        assert_eq!(map_ota_download_percent(0), 5);
        assert_eq!(map_ota_download_percent(50), 41);
        assert_eq!(map_ota_download_percent(100), 78);
        assert_eq!(map_ota_download_percent(150), 78);
    }
}
