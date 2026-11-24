//! 旧版固件独立引导升级模块（与正常设备 `ACTIVE_DEVICE` 状态机完全解耦）。
//!
//! 当某款硬件因固件版本过低无法走当前主协议连接时，通过独立生命周期会话完成：
//! 1. 以兼容旧协议建立控制通道（对 `dyj_v1` `< 0.8.0` 仅订阅 `FF11`，绝不碰无 Notify 的 `FF12`）；
//! 2. 查询设备版本号与当前 Wi-Fi 状态、扫描附近 Wi-Fi；
//! 3. 下发 Wi-Fi 凭据并等待真实联网成功（含对旧固件空密码覆盖风险的保护）；
//! 4. 触发设备下载安装新固件，监听下载/安装进度与覆盖安装预期断连；
//! 5. 等待设备重启自拉起并校验新协议特征就绪后，释放会话供上层自动重连蓝牙。

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use btleplug::api::{Central as _, CharPropFlags, Characteristic, Peripheral as _, ScanFilter, WriteType};
use btleplug::platform::{Adapter, Peripheral};
use futures::stream::StreamExt;
use serde_json::{json, Value};
use tokio::sync::{broadcast, Mutex as AsyncMutex};

use crate::dyj_v1_session::{
    find_gen1_legacy_char, parse_legacy_version_from_line, version_code_from_semver, COMMAND_UUID,
    DATA_UUID,
};
use crate::BridgeError;

const LEGACY_TARGET_VERSION: &str = "0.8.15";
const LEGACY_TARGET_VERSION_CODE: u64 = 815;
const LEGACY_TARGET_API_BASE: &str = "https://hdd.dev.reai.com/api";
const LEGACY_TARGET_OTA_INFO_URL: &str = "https://hdd.dev.reai.com/api/ota/info?mod=app";
const LEGACY_TARGET_OTA_APK_URL: &str = "https://hdd.dev.reai.com/ota/dyj1/app-815.apk";
const GATT_OP_TIMEOUT: Duration = Duration::from_secs(6);
const NOTIFY_SETTLE: Duration = Duration::from_millis(1200);
const GEN1_REBOOT_WAIT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone)]
enum LegacyUpgradeDriver {
    DyjV1(Arc<DyjV1LegacyUpgradeSession>),
    DyjV1Gen1(Arc<DyjV1Gen1LegacySession>),
}

impl LegacyUpgradeDriver {
    async fn scan_wifi(&self) -> Result<Value, BridgeError> {
        match self {
            Self::DyjV1(sess) => sess.scan_wifi().await,
            Self::DyjV1Gen1(sess) => sess.scan_wifi().await,
        }
    }

    async fn connect_wifi(&self, ssid: &str, password: Option<&str>) -> Result<Value, BridgeError> {
        match self {
            Self::DyjV1(sess) => sess.connect_wifi(ssid, password).await,
            Self::DyjV1Gen1(sess) => sess.connect_wifi(ssid, password).await,
        }
    }

    async fn run_ota(
        &self,
        payload: &Value,
        emit: &(dyn Fn(Value) + Send + Sync),
    ) -> Result<Value, BridgeError> {
        match self {
            Self::DyjV1(sess) => sess.run_ota(emit).await,
            Self::DyjV1Gen1(sess) => sess.run_ota(payload, emit).await,
        }
    }

    async fn close(&self) {
        match self {
            Self::DyjV1(sess) => sess.close().await,
            Self::DyjV1Gen1(sess) => sess.close().await,
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

/// 初代固件（`dyj-app-v1`, v0.5.x–v0.6.12）裸 JSON 流装帧器：
/// BLE Notify 无 `\r\n` 行尾分隔，按字节级 `{`/`}` 花括号配对（忽略字符串字面量内部括号）并完整保留跨分包的多字节 UTF-8。
#[derive(Default)]
pub(crate) struct Gen1JsonAssembler {
    raw: Vec<u8>,
}

impl Gen1JsonAssembler {
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        for &b in bytes {
            if b != 0 {
                self.raw.push(b);
            }
        }
        let mut out = Vec::new();
        let mut start: Option<usize> = None;
        let mut depth = 0usize;
        let mut in_string = false;
        let mut escaped = false;
        let mut consumed_to = 0usize;

        for (idx, &b) in self.raw.iter().enumerate() {
            if start.is_none() {
                if b == b'{' {
                    start = Some(idx);
                    depth = 1;
                    in_string = false;
                    escaped = false;
                }
                continue;
            }
            if in_string {
                if escaped {
                    escaped = false;
                } else if b == b'\\' {
                    escaped = true;
                } else if b == b'"' {
                    in_string = false;
                }
                continue;
            }
            match b {
                b'"' => in_string = true,
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        if let Some(s) = start {
                            out.push(String::from_utf8_lossy(&self.raw[s..=idx]).into_owned());
                        }
                        start = None;
                        consumed_to = idx + 1;
                    }
                }
                _ => {}
            }
        }

        if consumed_to > 0 {
            self.raw.drain(..consumed_to);
        } else if let Some(s) = start {
            if s > 0 {
                self.raw.drain(..s);
            }
        } else {
            self.raw.clear();
        }

        if self.raw.len() > 128 * 1024 {
            self.raw.clear();
        }
        out
    }
}

/// 构造 `dyj-app-v1` 线协议命令：`{"name": "<cmd>", "arguments": "<json_string>"}`。
/// 必须将 `arguments` 序列化为 JSON 字符串，以同时兼容 `v0.5.7–v0.5.15` 与 `v0.5.16–v0.6.12`。
pub(crate) fn build_gen1_request(name: &str, args: &Value) -> Vec<u8> {
    let args_str = serde_json::to_string(args).unwrap_or_else(|_| "{}".to_string());
    serde_json::to_vec(&json!({
        "name": name,
        "arguments": args_str,
    }))
    .unwrap_or_default()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TargetOtaSpec {
    pub version_name: String,
    pub version_code: u64,
    pub url: String,
}

pub fn default_target_ota_spec() -> TargetOtaSpec {
    TargetOtaSpec {
        version_name: LEGACY_TARGET_VERSION.to_string(),
        version_code: LEGACY_TARGET_VERSION_CODE,
        url: LEGACY_TARGET_OTA_APK_URL.to_string(),
    }
}

/// 解析来自 Dart/manifest 的 `targetOta` 升级清单。
pub fn parse_target_ota_spec(payload: &Value) -> Option<TargetOtaSpec> {
    let spec = payload.get("targetOta").unwrap_or(payload);
    let obj = spec.as_object()?;
    let raw_ver = obj
        .get("versionName")
        .or_else(|| obj.get("version"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(LEGACY_TARGET_VERSION)
        .trim_start_matches(['v', 'V'])
        .to_string();
    let url = obj
        .get("url")
        .or_else(|| obj.get("downloadUrl"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| s.starts_with("http://") || s.starts_with("https://"))?
        .to_string();
    let version_code = obj
        .get("versionCode")
        .and_then(|v| {
            v.as_u64()
                .or_else(|| v.as_str().and_then(|s| s.trim().parse::<u64>().ok()))
        })
        .filter(|&c| c > 0)
        .unwrap_or_else(|| version_code_from_semver(&raw_ver));
    if version_code == 0 {
        return None;
    }
    Some(TargetOtaSpec {
        version_name: raw_ver,
        version_code,
        url,
    })
}

/// 构造初代固件 `updateApp` OTA 请求：`versionCode` 必须传字符串（兼容 `v0.5.7–v0.5.20`），且带 `"force": true`。
pub fn build_gen1_update_app_request(spec: &TargetOtaSpec) -> Vec<u8> {
    let args = json!({
        "versionCode": spec.version_code.to_string(),
        "versionName": spec.version_name,
        "url": spec.url,
        "force": true,
    });
    build_gen1_request("updateApp", &args)
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParsedGen1Message {
    pub name: Option<String>,
    pub content: Value,
}

/// 解析初代固件 Notify JSON（兼容 `{"name":"...","content": {...|"<json>"}}` 与裸对象回包）。
pub fn parse_gen1_response(json_str: &str) -> Option<ParsedGen1Message> {
    let v: Value = serde_json::from_str(json_str.trim()).ok()?;
    let name = v
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    if let Some(content_val) = v.get("content") {
        let content = match content_val {
            Value::String(s) => {
                serde_json::from_str::<Value>(s).unwrap_or_else(|_| json!({ "message": s }))
            }
            other => other.clone(),
        };
        return Some(ParsedGen1Message { name, content });
    }
    Some(ParsedGen1Message { name, content: v })
}

/// 判断初代固件响应 `content` 是否代表显式错误（`ActionManager.successReturn` 省略 `code`，失败时带 `code != 0` 或 `success: false`）。
pub fn is_gen1_failure(content: &Value) -> Option<String> {
    let extract_msg = |v: &Value| {
        v.get("message")
            .or_else(|| v.get("error"))
            .or_else(|| v.get("msg"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("点一机操作失败")
            .to_string()
    };
    if content.get("success").and_then(Value::as_bool) == Some(false) {
        return Some(extract_msg(content));
    }
    if content.get("code").and_then(Value::as_i64).is_some_and(|c| c != 0) {
        return Some(extract_msg(content));
    }
    if let Some(data) = content.get("data") {
        if data.get("success").and_then(Value::as_bool) == Some(false) {
            return Some(extract_msg(data));
        }
        if data.get("code").and_then(Value::as_i64).is_some_and(|c| c != 0) {
            return Some(extract_msg(data));
        }
    }
    None
}

/// 从初代固件 `infoGet(wifiList)` 切片汇总并去重排序 Wi-Fi 列表。
pub fn aggregate_gen1_wifi_networks(items: &[Value]) -> Value {
    let mut best_by_ssid: HashMap<String, LegacyWifiNetwork> = HashMap::new();
    let mut active_ssid: Option<String> = None;

    for raw_item in items {
        let entry = raw_item.get("item").unwrap_or(raw_item);
        let ssid = entry
            .get("ssid")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        if ssid.is_empty() {
            continue;
        }
        let rssi = entry
            .get("signalStrength")
            .or_else(|| entry.get("level"))
            .or_else(|| entry.get("rssi"))
            .and_then(Value::as_i64)
            .unwrap_or(-90);
        let connected = entry
            .get("isConnected")
            .or_else(|| entry.get("connected"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if connected {
            active_ssid = Some(ssid.to_string());
        }
        let secure = if let Some(caps) = entry.get("capabilities").and_then(Value::as_str) {
            is_legacy_capabilities_secured(caps)
        } else if let Some(sec) = entry.get("security").and_then(Value::as_str) {
            let u = sec.trim().to_ascii_uppercase();
            !u.is_empty() && u != "NONE" && u != "OPEN"
        } else {
            true
        };
        let net = LegacyWifiNetwork {
            ssid: ssid.to_string(),
            rssi,
            secure,
            connected,
        };
        best_by_ssid
            .entry(ssid.to_string())
            .and_modify(|prev| {
                if net.rssi > prev.rssi {
                    prev.rssi = net.rssi;
                }
                prev.connected |= net.connected;
            })
            .or_insert(net);
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

/// 升级重启后在扫描到的候选中定位目标设备：
/// 1) 优先同 peripheral ID；2) 其次同原始名称；3) 其次是重启后新出现的 `DYJ_` 设备（适配 `0.5/0.6.x` `DYJ-*` 升级至 `0.7.2/0.8.x` 后重置为 `DYJ_*` 的名称变更）。
pub fn select_post_upgrade_candidate<'a>(
    candidates: &'a [(String, String)],
    orig_id: &str,
    orig_name: &str,
    baseline_dyj_names: &HashSet<String>,
) -> Option<&'a (String, String)> {
    let trimmed_orig_id = orig_id.trim();
    if !trimmed_orig_id.is_empty() {
        if let Some(m) = candidates.iter().find(|(id, _)| id == trimmed_orig_id) {
            return Some(m);
        }
    }
    let trimmed_orig_name = orig_name.trim();
    if !trimmed_orig_name.is_empty() {
        if let Some(m) = candidates
            .iter()
            .find(|(_, name)| name.trim() == trimmed_orig_name)
        {
            return Some(m);
        }
    }
    candidates.iter().find(|(_, name)| {
        let t = name.trim();
        t.to_ascii_uppercase().starts_with("DYJ_") && !baseline_dyj_names.contains(t)
    })
}

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

async fn connect_and_discover(
    adapter: &Adapter,
    id_hint: &str,
    name_hint: &str,
) -> Result<(Peripheral, String, BTreeSet<Characteristic>), BridgeError> {
    let peripheral = resolve_peripheral(adapter, id_hint, name_hint).await?;
    let actual_id = peripheral.id().to_string();

    match tokio::time::timeout(Duration::from_secs(12), peripheral.connect()).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            return Err(BridgeError::from(format!("连接点一机旧固件通道失败：{e}")));
        }
        Err(_) => {
            let _ = tokio::time::timeout(Duration::from_secs(2), peripheral.disconnect()).await;
            return Err(BridgeError::from("连接点一机旧固件通道超时，请重试".to_string()));
        }
    }

    if !matches!(
        tokio::time::timeout(Duration::from_secs(8), peripheral.discover_services()).await,
        Ok(Ok(()))
    ) {
        let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
        return Err(BridgeError::from("点一机旧固件服务发现失败，请重试".to_string()));
    }

    let chars = peripheral.characteristics();
    Ok((peripheral, actual_id, chars))
}

async fn collect_dyj_names(adapter: &Adapter) -> HashSet<String> {
    let mut names = HashSet::new();
    let Ok(peripherals) = adapter.peripherals().await else {
        return names;
    };
    for p in &peripherals {
        if let Some(local) = read_peripheral_name(p).await {
            if local.to_ascii_uppercase().starts_with("DYJ_") {
                names.insert(local);
            }
        }
    }
    names
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
    pub(crate) async fn from_connected(
        adapter: &Adapter,
        peripheral: Peripheral,
        actual_id: String,
        name_hint: &str,
        cmd_char: Characteristic,
    ) -> Result<(Arc<Self>, Value), BridgeError> {
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

async fn write_gen1_packet(
    peripheral: &Peripheral,
    ch: &Characteristic,
    bytes: &[u8],
) -> Result<(), BridgeError> {
    let write_type = if ch.properties.contains(CharPropFlags::WRITE) {
        WriteType::WithResponse
    } else {
        WriteType::WithoutResponse
    };
    tokio::time::timeout(
        Duration::from_secs(4),
        peripheral.write(ch, bytes, write_type),
    )
    .await
    .map_err(|_| BridgeError::from("向初代点一机写入命令超时".to_string()))?
    .map_err(|e| BridgeError::from(format!("向初代点一机写入命令失败：{e}")))
}

fn extract_gen1_update_state(content: &Value) -> (String, u64, Option<String>) {
    let obj = content.get("data").unwrap_or(content);
    let state = obj
        .get("state")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("")
        .to_ascii_lowercase();
    let progress = obj
        .get("progress")
        .and_then(|v| {
            v.as_u64()
                .or_else(|| v.as_f64().map(|f| f.round().max(0.0) as u64))
                .or_else(|| v.as_str().and_then(|s| s.trim().parse::<u64>().ok()))
        })
        .unwrap_or(0);
    let err = obj
        .get("error")
        .or_else(|| obj.get("message"))
        .or_else(|| obj.get("msg"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    (state, progress, err)
}

fn extract_gen1_base_version(msg: &ParsedGen1Message) -> Option<String> {
    if let Some(ver) = parse_legacy_version_from_line(&msg.content.to_string()) {
        return Some(ver);
    }
    let data = msg.content.get("data").unwrap_or(&msg.content);
    let code = data.get("versionCode").and_then(Value::as_u64)?;
    if code == 0 {
        return None;
    }
    let maj = code / 10_000;
    let min = (code % 10_000) / 100;
    let pat = code % 100;
    Some(format!("{maj}.{min}.{pat}"))
}

#[derive(Clone)]
struct Gen1Transport {
    peripheral: Peripheral,
    gen1_char: Characteristic,
    msg_tx: broadcast::Sender<Result<ParsedGen1Message, String>>,
    disconnected: Arc<AtomicBool>,
}

#[derive(Clone)]
enum Gen1LiveState {
    Gen1(Gen1Transport),
    UpgradedToFf11(Arc<DyjV1LegacyUpgradeSession>),
    Closed,
}

pub struct DyjV1Gen1LegacySession {
    adapter: Adapter,
    device_id: AsyncMutex<String>,
    device_name: AsyncMutex<String>,
    live: AsyncMutex<Gen1LiveState>,
    op_lock: AsyncMutex<()>,
    baseline_dyj_names: AsyncMutex<HashSet<String>>,
    last_wifi: AsyncMutex<Option<(String, Option<String>)>>,
}

impl DyjV1Gen1LegacySession {
    async fn spawn_transport(
        peripheral: Peripheral,
        gen1_char: Characteristic,
    ) -> Result<Gen1Transport, BridgeError> {
        let notifications = match tokio::time::timeout(Duration::from_secs(5), peripheral.notifications()).await {
            Ok(Ok(s)) => s,
            _ => {
                let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
                return Err(BridgeError::from("建立初代点一机通知监听失败，请重试".to_string()));
            }
        };

        match tokio::time::timeout(GATT_OP_TIMEOUT, peripheral.subscribe(&gen1_char)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                log::warn!(
                    "legacy_upgrade(gen1): subscribe({}) 返回错误（继续尽力通信）: {e}",
                    gen1_char.uuid
                );
            }
            Err(_) => {
                let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
                return Err(BridgeError::from("订阅初代点一机控制通道超时，请重试".to_string()));
            }
        }

        tokio::time::sleep(Duration::from_millis(120)).await;

        let (msg_tx, _) = broadcast::channel::<Result<ParsedGen1Message, String>>(128);
        let disconnected = Arc::new(AtomicBool::new(false));
        let tx_clone = msg_tx.clone();
        let disc_clone = disconnected.clone();
        let peripheral_watch = peripheral.clone();
        let watch_uuid = gen1_char.uuid;

        tokio::spawn(async move {
            let mut stream = notifications;
            let mut assembler = Gen1JsonAssembler::default();
            loop {
                let next_note = tokio::time::timeout(Duration::from_secs(2), stream.next()).await;
                match next_note {
                    Ok(Some(note)) => {
                        if note.uuid != watch_uuid {
                            continue;
                        }
                        for obj_str in assembler.feed(&note.value) {
                            if let Some(parsed) = parse_gen1_response(&obj_str) {
                                let _ = tx_clone.send(Ok(parsed));
                            }
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

        Ok(Gen1Transport {
            peripheral,
            gen1_char,
            msg_tx,
            disconnected,
        })
    }

    async fn request_on(
        t: &Gen1Transport,
        name: &str,
        args: &Value,
        expected_key: Option<&str>,
        timeout: Duration,
    ) -> Result<ParsedGen1Message, BridgeError> {
        if t.disconnected.load(Ordering::SeqCst) {
            return Err(BridgeError::from("与点一机的蓝牙连接已断开".to_string()));
        }
        let mut rx = t.msg_tx.subscribe();
        let req_bytes = build_gen1_request(name, args);
        write_gen1_packet(&t.peripheral, &t.gen1_char, &req_bytes).await?;

        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
            if rem.is_zero() {
                return Err(BridgeError::from(format!("等待初代点一机响应 {name} 超时")));
            }
            match tokio::time::timeout(rem, rx.recv()).await {
                Ok(Ok(Ok(parsed))) => {
                    if is_gen1_failure(&parsed.content).is_some()
                        && (parsed.name.as_deref() == Some(name) || parsed.name.is_none())
                    {
                        return Ok(parsed);
                    }
                    if let Some(k) = expected_key {
                        let content_key = parsed.content.get("key").and_then(Value::as_str);
                        if content_key == Some(k)
                            || (parsed.name.as_deref() == Some(name) && content_key.is_none())
                        {
                            return Ok(parsed);
                        }
                    } else if parsed.name.as_deref() == Some(name) {
                        return Ok(parsed);
                    }
                }
                Ok(Ok(Err(_))) => return Err(BridgeError::from("与点一机的蓝牙连接已断开".to_string())),
                Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(_)) => return Err(BridgeError::from("初代点一机控制通道已关闭".to_string())),
                Err(_) => return Err(BridgeError::from(format!("等待初代点一机响应 {name} 超时"))),
            }
        }
    }

    async fn fetch_wifi_items(t: &Gen1Transport, timeout: Duration) -> Result<Vec<Value>, BridgeError> {
        if t.disconnected.load(Ordering::SeqCst) {
            return Err(BridgeError::from("与点一机的蓝牙连接已断开".to_string()));
        }
        let mut rx = t.msg_tx.subscribe();
        let req_bytes = build_gen1_request("infoGet", &json!({ "key": "wifiList" }));
        write_gen1_packet(&t.peripheral, &t.gen1_char, &req_bytes).await?;

        let mut items = Vec::new();
        let mut expected_size: Option<usize> = None;
        let deadline = tokio::time::Instant::now() + timeout;
        let empty_deadline = tokio::time::Instant::now() + Duration::from_secs(4);
        loop {
            let now = tokio::time::Instant::now();
            let stop_at = if items.is_empty() {
                empty_deadline.min(deadline)
            } else {
                deadline
            };
            let rem = stop_at.saturating_duration_since(now);
            if rem.is_zero() {
                break;
            }
            match tokio::time::timeout(rem, rx.recv()).await {
                Ok(Ok(Ok(parsed))) => {
                    let is_wifi_list = parsed.content.get("key").and_then(Value::as_str) == Some("wifiList")
                        || (parsed.name.as_deref() == Some("infoGet")
                            && parsed.content.get("data").and_then(|d| d.get("item")).is_some());
                    if !is_wifi_list {
                        if let Some(err) = is_gen1_failure(&parsed.content) {
                            if parsed.name.as_deref() == Some("infoGet") {
                                return Err(BridgeError::from(err));
                            }
                        }
                        continue;
                    }
                    if let Some(err) = is_gen1_failure(&parsed.content) {
                        return Err(BridgeError::from(err));
                    }
                    let data = parsed.content.get("data").unwrap_or(&parsed.content);
                    if let Some(sz) = data.get("size").and_then(Value::as_u64) {
                        expected_size = Some(sz as usize);
                        if sz == 0 {
                            break;
                        }
                    }
                    items.push(data.clone());
                    if expected_size.is_some_and(|n| items.len() >= n) {
                        break;
                    }
                }
                Ok(Ok(Err(_))) => return Err(BridgeError::from("与点一机的蓝牙连接已断开".to_string())),
                Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(_)) | Err(_) => break,
            }
        }
        Ok(items)
    }

    pub(crate) async fn from_connected(
        adapter: &Adapter,
        peripheral: Peripheral,
        actual_id: String,
        name_hint: &str,
        gen1_char: Characteristic,
    ) -> Result<(Arc<Self>, Value), BridgeError> {
        let transport = Self::spawn_transport(peripheral, gen1_char).await?;

        let base_msg = Self::request_on(
            &transport,
            "infoGet",
            &json!({ "key": "base" }),
            Some("base"),
            Duration::from_secs(6),
        )
        .await?;
        let base_data = base_msg.content.get("data").unwrap_or(&base_msg.content);
        let current_ver = extract_gen1_base_version(&base_msg).unwrap_or_else(|| "0.6.0".to_string());
        let resolved_name = base_data
            .get("deviceName")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| name_hint.trim())
            .to_string();

        let net_msg = Self::request_on(
            &transport,
            "infoGet",
            &json!({ "key": "network" }),
            Some("network"),
            Duration::from_secs(4),
        )
        .await
        .ok();
        let net_type = net_msg
            .as_ref()
            .and_then(|m| {
                m.content
                    .get("data")
                    .unwrap_or(&m.content)
                    .get("networkType")
                    .and_then(Value::as_str)
            })
            .unwrap_or("")
            .trim()
            .to_ascii_uppercase();
        let wifi_connected = net_type == "WIFI";

        let baseline = collect_dyj_names(adapter).await;

        let info = json!({
            "deviceId": actual_id,
            "name": resolved_name,
            "deviceKind": "dyj_v1",
            "currentVersion": current_ver,
            "targetVersion": LEGACY_TARGET_VERSION,
            "wifiEnabled": true,
            "wifiConnected": wifi_connected,
            "currentSsid": Value::Null,
        });

        let session = Arc::new(Self {
            adapter: adapter.clone(),
            device_id: AsyncMutex::new(actual_id),
            device_name: AsyncMutex::new(resolved_name),
            live: AsyncMutex::new(Gen1LiveState::Gen1(transport)),
            op_lock: AsyncMutex::new(()),
            baseline_dyj_names: AsyncMutex::new(baseline),
            last_wifi: AsyncMutex::new(None),
        });

        Ok((session, info))
    }

    async fn live_transport(&self) -> Result<Result<Gen1Transport, Arc<DyjV1LegacyUpgradeSession>>, BridgeError> {
        match &*self.live.lock().await {
            Gen1LiveState::Gen1(t) => Ok(Ok(t.clone())),
            Gen1LiveState::UpgradedToFf11(ff11) => Ok(Err(ff11.clone())),
            Gen1LiveState::Closed => Err(BridgeError::from("旧固件升级会话已关闭".to_string())),
        }
    }

    pub(crate) async fn scan_wifi(&self) -> Result<Value, BridgeError> {
        let _op = self.op_lock.lock().await;
        match self.live_transport().await? {
            Err(ff11) => ff11.scan_wifi().await,
            Ok(t) => {
                let items = Self::fetch_wifi_items(&t, Duration::from_secs(9)).await?;
                Ok(aggregate_gen1_wifi_networks(&items))
            }
        }
    }

    async fn check_wifi_network_online(t: &Gen1Transport, target_ssid: &str) -> bool {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
        while tokio::time::Instant::now() < deadline {
            if let Ok(net) = Self::request_on(
                t,
                "infoGet",
                &json!({ "key": "network" }),
                Some("network"),
                Duration::from_secs(3),
            )
            .await
            {
                let nt = net
                    .content
                    .get("data")
                    .unwrap_or(&net.content)
                    .get("networkType")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim();
                if nt.eq_ignore_ascii_case("WIFI") {
                    return true;
                }
            }
            tokio::time::sleep(Duration::from_millis(900)).await;
        }
        if let Ok(items) = Self::fetch_wifi_items(t, Duration::from_secs(4)).await {
            let agg = aggregate_gen1_wifi_networks(&items);
            return agg
                .get("currentSsid")
                .and_then(Value::as_str)
                .is_some_and(|s| s.trim() == target_ssid);
        }
        false
    }

    async fn reconnect_after_wifi_set(
        &self,
        orig_id: &str,
        orig_name: &str,
        baseline: &HashSet<String>,
        target_ssid: &str,
        password: Option<&str>,
    ) -> Result<Value, BridgeError> {
        let deadline = Instant::now() + Duration::from_secs(28);
        while Instant::now() < deadline {
            if let Some((found_id, found_name, p)) =
                scan_for_post_gen1_candidate(&self.adapter, orig_id, orig_name, baseline).await
            {
                if !matches!(
                    tokio::time::timeout(Duration::from_secs(10), p.connect()).await,
                    Ok(Ok(()))
                ) {
                    let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
                    tokio::time::sleep(Duration::from_millis(900)).await;
                    continue;
                }
                if !matches!(
                    tokio::time::timeout(Duration::from_secs(8), p.discover_services()).await,
                    Ok(Ok(()))
                ) {
                    let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
                    tokio::time::sleep(Duration::from_millis(900)).await;
                    continue;
                }

                let chars = p.characteristics();
                if let Some(ff11_char) = chars
                    .iter()
                    .find(|c| c.uuid.to_string().eq_ignore_ascii_case(COMMAND_UUID))
                    .cloned()
                {
                    let (ff11_sess, info) = DyjV1LegacyUpgradeSession::from_connected(
                        &self.adapter,
                        p,
                        found_id.clone(),
                        &found_name,
                        ff11_char,
                    )
                    .await?;
                    let res = if info.get("wifiConnected").and_then(Value::as_bool) == Some(true)
                        && info.get("currentSsid").and_then(Value::as_str).map(str::trim) == Some(target_ssid)
                    {
                        json!({ "connected": true, "ssid": target_ssid, "ip": "" })
                    } else {
                        ff11_sess.connect_wifi(target_ssid, password).await?
                    };
                    *self.device_id.lock().await = found_id;
                    *self.device_name.lock().await = found_name;
                    *self.live.lock().await = Gen1LiveState::UpgradedToFf11(ff11_sess);
                    return Ok(res);
                }

                if let Some(gen1_char) = find_gen1_legacy_char(&chars) {
                    let new_t = Self::spawn_transport(p, gen1_char).await?;
                    let online = Self::check_wifi_network_online(&new_t, target_ssid).await;
                    *self.device_id.lock().await = found_id;
                    *self.device_name.lock().await = found_name;
                    *self.live.lock().await = Gen1LiveState::Gen1(new_t);
                    if online {
                        return Ok(json!({
                            "connected": true,
                            "ssid": target_ssid,
                            "ip": "",
                        }));
                    }
                    return Err(BridgeError::from(
                        "Wi-Fi 连接未成功，请核对密码是否为 2.4GHz 网络密码后重试".to_string(),
                    ));
                }

                let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
            }
            tokio::time::sleep(Duration::from_millis(1000)).await;
        }

        Err(BridgeError::from(
            "配置 Wi-Fi 后等待点一机重新连接超时，请确认设备已开机并重试".to_string(),
        ))
    }

    pub(crate) async fn connect_wifi(&self, ssid: &str, password: Option<&str>) -> Result<Value, BridgeError> {
        let _op = self.op_lock.lock().await;
        let target_ssid = ssid.trim();
        if target_ssid.is_empty() {
            return Err(BridgeError::from("请选择要连接的 Wi-Fi 网络".to_string()));
        }

        let t = match self.live_transport().await? {
            Err(ff11) => {
                *self.last_wifi.lock().await = Some((target_ssid.to_string(), password.map(str::to_string)));
                return ff11.connect_wifi(target_ssid, password).await;
            }
            Ok(t) => t,
        };

        if password.is_none_or(|p| p.trim().is_empty()) {
            if let Ok(items) = Self::fetch_wifi_items(&t, Duration::from_secs(4)).await {
                let agg = aggregate_gen1_wifi_networks(&items);
                if agg
                    .get("currentSsid")
                    .and_then(Value::as_str)
                    .is_some_and(|s| s.trim() == target_ssid)
                {
                    *self.last_wifi.lock().await = Some((target_ssid.to_string(), None));
                    return Ok(json!({
                        "connected": true,
                        "ssid": target_ssid,
                        "ip": "",
                    }));
                }
            }
        }

        let mut rx = t.msg_tx.subscribe();
        let req_bytes = build_gen1_request(
            "wifiSet",
            &json!({
                "name": target_ssid,
                "pd": password.unwrap_or(""),
            }),
        );
        let send_started = Instant::now();
        write_gen1_packet(&t.peripheral, &t.gen1_char, &req_bytes).await?;

        let deadline = tokio::time::Instant::now() + Duration::from_secs(36);
        loop {
            let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
            if rem.is_zero() {
                return Err(BridgeError::from(
                    "Wi-Fi 连接超时，请核对 2.4GHz 网络密码后重试".to_string(),
                ));
            }
            match tokio::time::timeout(rem, rx.recv()).await {
                Ok(Ok(Ok(parsed))) if parsed.name.as_deref() == Some("wifiSet") => {
                    if let Some(err) = is_gen1_failure(&parsed.content) {
                        return Err(BridgeError::from(err));
                    }
                    break;
                }
                Ok(Ok(Ok(_))) => continue,
                Ok(Ok(Err(_))) => {
                    if send_started.elapsed() >= Duration::from_secs(1) {
                        break;
                    }
                    return Err(BridgeError::from("配置 Wi-Fi 过程中蓝牙意外断开，请重试".to_string()));
                }
                Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(_)) => {
                    if send_started.elapsed() >= Duration::from_secs(1) {
                        break;
                    }
                    return Err(BridgeError::from("初代点一机控制通道意外关闭".to_string()));
                }
                Err(_) => {
                    return Err(BridgeError::from(
                        "Wi-Fi 连接超时，请核对 2.4GHz 网络密码后重试".to_string(),
                    ));
                }
            }
        }

        *self.last_wifi.lock().await = Some((target_ssid.to_string(), password.map(str::to_string)));
        let orig_id = self.device_id.lock().await.clone();
        let orig_name = self.device_name.lock().await.clone();
        let baseline = {
            let mut guard = self.baseline_dyj_names.lock().await;
            let mut merged = guard.clone();
            for n in collect_dyj_names(&self.adapter).await {
                merged.insert(n);
            }
            *guard = merged.clone();
            merged
        };

        // wifiSet 成功后固件延迟 1s 调用 SystemUtils.restartApp()，主动释放旧连接并等新进程重拉广播
        tokio::time::sleep(Duration::from_millis(2200)).await;
        t.disconnected.store(true, Ordering::SeqCst);
        let _ = tokio::time::timeout(Duration::from_secs(2), t.peripheral.disconnect()).await;
        tokio::time::sleep(Duration::from_millis(1200)).await;

        self.reconnect_after_wifi_set(&orig_id, &orig_name, &baseline, target_ssid, password)
            .await
    }

    pub(crate) async fn run_ota(
        &self,
        payload: &Value,
        emit: &(dyn Fn(Value) + Send + Sync),
    ) -> Result<Value, BridgeError> {
        let _op = self.op_lock.lock().await;
        let t = match self.live_transport().await? {
            Err(ff11) => return ff11.run_ota(emit).await,
            Ok(t) => t,
        };

        let spec = parse_target_ota_spec(payload).unwrap_or_else(default_target_ota_spec);
        emit(json!({
            "stage": "checking",
            "percent": 2,
            "text": "正在检查点一机固件更新状态…",
            "version": spec.version_name,
        }));

        let baseline = {
            let mut guard = self.baseline_dyj_names.lock().await;
            let mut merged = guard.clone();
            for n in collect_dyj_names(&self.adapter).await {
                merged.insert(n);
            }
            *guard = merged.clone();
            merged
        };

        let pre_state = Self::request_on(
            &t,
            "updateState",
            &json!({}),
            None,
            Duration::from_secs(4),
        )
        .await
        .ok()
        .map(|m| extract_gen1_update_state(&m.content).0)
        .unwrap_or_default();

        let already_running = matches!(
            pre_state.as_str(),
            "downloading" | "installing" | "completed" | "success"
        );

        let mut rx = t.msg_tx.subscribe();
        let mut max_dl_pct = 0u64;
        let mut entered_installing = pre_state == "installing";
        let mut seen_active = already_running;

        if !already_running {
            let req_bytes = build_gen1_update_app_request(&spec);
            write_gen1_packet(&t.peripheral, &t.gen1_char, &req_bytes).await?;

            // 等初始 updateApp 确认包或首条状态推送（最多 8s），若返回明确错误且非“升级中”则中止
            let ack_deadline = tokio::time::Instant::now() + Duration::from_secs(8);
            while tokio::time::Instant::now() < ack_deadline {
                let rem = ack_deadline.saturating_duration_since(tokio::time::Instant::now());
                match tokio::time::timeout(rem, rx.recv()).await {
                    Ok(Ok(Ok(parsed))) if parsed.name.as_deref() == Some("updateApp") => {
                        if let Some(err) = is_gen1_failure(&parsed.content) {
                            let lower = err.to_ascii_lowercase();
                            if err.contains("正在") || lower.contains("already") || lower.contains("progress") {
                                seen_active = true;
                                break;
                            }
                            return Err(BridgeError::from(err));
                        }
                        break;
                    }
                    Ok(Ok(Ok(parsed))) if parsed.name.as_deref() == Some("updateState") => {
                        let (st, pct, err_opt) = extract_gen1_update_state(&parsed.content);
                        if matches!(st.as_str(), "downloading" | "installing" | "completed" | "success") {
                            seen_active = true;
                            max_dl_pct = max_dl_pct.max(pct);
                            if st == "installing" {
                                entered_installing = true;
                            }
                            break;
                        }
                        if matches!(st.as_str(), "error" | "failed") {
                            return Err(BridgeError::from(
                                err_opt.unwrap_or_else(|| "点一机固件更新失败".to_string()),
                            ));
                        }
                    }
                    Ok(Ok(Err(_))) => break,
                    Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                    _ => break,
                }
            }
        }

        emit(json!({
            "stage": if entered_installing { "installing" } else { "downloading" },
            "percent": if entered_installing { 84 } else { 4 },
            "text": if entered_installing { "正在安装新固件，即将重启…".to_string() } else { "正在下载新固件 0%…".to_string() },
            "version": spec.version_name,
        }));

        let mut ota_error: Option<String> = None;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
        let mut install_deadline: Option<tokio::time::Instant> =
            entered_installing.then(|| tokio::time::Instant::now() + Duration::from_secs(60));
        let mut next_poll_at = tokio::time::Instant::now() + Duration::from_millis(1200);
        let mut idle_ticks = 0u32;

        if pre_state != "completed" && pre_state != "success" {
            loop {
                let now = tokio::time::Instant::now();
                let effective_deadline = install_deadline.map_or(deadline, |d| d.min(deadline));
                if now >= effective_deadline {
                    if entered_installing || max_dl_pct >= 90 {
                        break;
                    }
                    ota_error = Some("固件下载或安装超时，请保持设备供电与 Wi-Fi 畅通后重试".to_string());
                    break;
                }

                if now >= next_poll_at {
                    if !t.disconnected.load(Ordering::SeqCst) {
                        let poll_bytes = build_gen1_request("updateState", &json!({}));
                        let _ = write_gen1_packet(&t.peripheral, &t.gen1_char, &poll_bytes).await;
                    }
                    next_poll_at = tokio::time::Instant::now() + Duration::from_millis(1200);
                }

                let wait_dur = next_poll_at
                    .min(effective_deadline)
                    .saturating_duration_since(tokio::time::Instant::now())
                    .max(Duration::from_millis(50));

                match tokio::time::timeout(wait_dur, rx.recv()).await {
                    Ok(Ok(Ok(parsed)))
                        if matches!(parsed.name.as_deref(), Some("updateState" | "updateApp")) =>
                    {
                        let (st, pct, err_opt) = extract_gen1_update_state(&parsed.content);
                        match st.as_str() {
                            "downloading" => {
                                seen_active = true;
                                idle_ticks = 0;
                                if pct > max_dl_pct {
                                    max_dl_pct = pct;
                                }
                                emit(json!({
                                    "stage": "downloading",
                                    "percent": map_ota_download_percent(max_dl_pct),
                                    "text": format!("正在下载新固件 {}%…", max_dl_pct.min(100)),
                                    "version": spec.version_name,
                                }));
                            }
                            "installing" => {
                                seen_active = true;
                                entered_installing = true;
                                install_deadline.get_or_insert_with(|| {
                                    tokio::time::Instant::now() + Duration::from_secs(60)
                                });
                                emit(json!({
                                    "stage": "installing",
                                    "percent": 84,
                                    "text": "下载完成，正在安装新固件，即将重启…",
                                    "version": spec.version_name,
                                }));
                            }
                            "completed" | "success" => {
                                break;
                            }
                            "error" | "failed" => {
                                ota_error = Some(err_opt.unwrap_or_else(|| "新固件下载或安装失败".to_string()));
                                break;
                            }
                            "idle" => {
                                idle_ticks += 1;
                                if entered_installing || max_dl_pct >= 90 {
                                    break;
                                }
                                if !seen_active && idle_ticks >= 15 {
                                    ota_error = Some("点一机未开始下载固件，请检查 Wi-Fi 外网连通性后重试".to_string());
                                    break;
                                }
                            }
                            _ => {
                                if let Some(err) = is_gen1_failure(&parsed.content) {
                                    ota_error = Some(err);
                                    break;
                                }
                            }
                        }
                    }
                    Ok(Ok(Ok(_))) => continue,
                    Ok(Ok(Err(_))) => {
                        if entered_installing || max_dl_pct >= 88 {
                            break;
                        }
                        ota_error = Some("升级过程中点一机蓝牙意外断开，请确认电量后重试".to_string());
                        break;
                    }
                    Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                    Ok(Err(_)) => {
                        if entered_installing || max_dl_pct >= 88 {
                            break;
                        }
                        ota_error = Some("升级状态通道意外关闭".to_string());
                        break;
                    }
                    Err(_) => continue,
                }
            }
        }

        if let Some(err) = ota_error {
            return Err(BridgeError::from(err));
        }

        t.disconnected.store(true, Ordering::SeqCst);
        let _ = tokio::time::timeout(Duration::from_secs(3), t.peripheral.disconnect()).await;

        emit(json!({
            "stage": "rebooting",
            "percent": 88,
            "text": "安装完成，正在等待点一机重启（约 1 分钟）…",
            "version": spec.version_name,
        }));

        tokio::time::sleep(Duration::from_secs(8)).await;

        let orig_id = self.device_id.lock().await.clone();
        let orig_name = self.device_name.lock().await.clone();
        let saved_wifi = self.last_wifi.lock().await.clone();

        let scan_deadline = Instant::now() + GEN1_REBOOT_WAIT_TIMEOUT;
        while Instant::now() < scan_deadline {
            if let Some((found_id, found_name, p)) =
                scan_for_post_gen1_candidate(&self.adapter, &orig_id, &orig_name, &baseline).await
            {
                if !matches!(
                    tokio::time::timeout(Duration::from_secs(8), p.connect()).await,
                    Ok(Ok(()))
                ) {
                    let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
                    tokio::time::sleep(Duration::from_millis(1200)).await;
                    continue;
                }
                if !matches!(
                    tokio::time::timeout(Duration::from_secs(6), p.discover_services()).await,
                    Ok(Ok(()))
                ) {
                    let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
                    tokio::time::sleep(Duration::from_millis(1200)).await;
                    continue;
                }

                let chars = p.characteristics();
                let ff11_char = chars
                    .iter()
                    .find(|c| c.uuid.to_string().eq_ignore_ascii_case(COMMAND_UUID))
                    .cloned();
                let has_ff12_notify = chars.iter().any(|c| {
                    c.uuid.to_string().eq_ignore_ascii_case(DATA_UUID)
                        && c.properties.contains(CharPropFlags::NOTIFY)
                });

                if ff11_char.is_some() && has_ff12_notify {
                    let _ = tokio::time::timeout(Duration::from_secs(3), p.disconnect()).await;
                    tokio::time::sleep(Duration::from_millis(1200)).await;
                    emit(json!({
                        "stage": "done",
                        "percent": 100,
                        "text": "点一机已升级就绪，正在自动连接蓝牙…",
                        "version": spec.version_name,
                    }));
                    return Ok(json!({
                        "ok": true,
                        "deviceId": found_id,
                        "name": found_name,
                        "targetVersion": spec.version_name,
                    }));
                }

                // 若开机自检先升到了 v0.7.2（有 FF11 但 FF12 无 Notify），无缝串接第二跳升级至最新版
                if let Some(cmd_char) = ff11_char {
                    emit(json!({
                        "stage": "downloading",
                        "percent": 89,
                        "text": "已升级至过渡版固件，正在继续自动升级至最新版…",
                        "version": spec.version_name,
                    }));
                    let (ff11_sess, info) = DyjV1LegacyUpgradeSession::from_connected(
                        &self.adapter,
                        p,
                        found_id,
                        &found_name,
                        cmd_char,
                    )
                    .await?;
                    if info.get("wifiConnected").and_then(Value::as_bool) != Some(true) {
                        if let Some((ref ssid, ref pwd)) = saved_wifi {
                            ff11_sess.connect_wifi(ssid, pwd.as_deref()).await?;
                        }
                    }
                    let hop2_emit = |mut ev: Value| {
                        if let Some(pct) = ev.get("percent").and_then(Value::as_u64) {
                            let remapped = 89 + ((pct.min(100) * 11) / 100);
                            ev["percent"] = json!(remapped);
                        }
                        emit(ev);
                    };
                    let res = ff11_sess.run_ota(&hop2_emit).await;
                    ff11_sess.close().await;
                    return res;
                }

                let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
            }
            tokio::time::sleep(Duration::from_millis(1500)).await;
        }

        Err(BridgeError::from(
            "点一机安装完成但等待重启恢复超时，请返回列表重新扫描连接".to_string(),
        ))
    }

    pub async fn close(&self) {
        let prev = std::mem::replace(&mut *self.live.lock().await, Gen1LiveState::Closed);
        match prev {
            Gen1LiveState::Gen1(t) => {
                t.disconnected.store(true, Ordering::SeqCst);
                let _ = tokio::time::timeout(Duration::from_secs(3), t.peripheral.disconnect()).await;
            }
            Gen1LiveState::UpgradedToFf11(ff11) => ff11.close().await,
            Gen1LiveState::Closed => {}
        }
    }
}

async fn scan_for_post_gen1_candidate(
    adapter: &Adapter,
    orig_id: &str,
    orig_name: &str,
    baseline_dyj_names: &HashSet<String>,
) -> Option<(String, String, Peripheral)> {
    let _ = adapter.start_scan(ScanFilter::default()).await;
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut matched = None;
    while Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(700)).await;
        let Ok(peripherals) = adapter.peripherals().await else {
            continue;
        };
        let mut candidates = Vec::new();
        let mut by_id = HashMap::new();
        for p in peripherals {
            let pid = p.id().to_string();
            let name = read_peripheral_name(&p).await.unwrap_or_default();
            let is_dyj = name.to_ascii_uppercase().starts_with("DYJ_")
                || name.to_ascii_uppercase().starts_with("DYJ-");
            if pid == orig_id || is_dyj {
                candidates.push((pid.clone(), name));
                by_id.insert(pid, p);
            }
        }
        if let Some((id, name)) =
            select_post_upgrade_candidate(&candidates, orig_id, orig_name, baseline_dyj_names)
        {
            if let Some(p) = by_id.remove(id) {
                matched = Some((id.clone(), name.clone(), p));
                break;
            }
        }
    }
    let _ = adapter.stop_scan().await;
    matched
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
            let (peripheral, actual_id, chars) = connect_and_discover(adapter, id, name).await?;
            if let Some(cmd_char) = chars
                .iter()
                .find(|c| c.uuid.to_string().eq_ignore_ascii_case(COMMAND_UUID))
                .cloned()
            {
                let (sess, info) = DyjV1LegacyUpgradeSession::from_connected(
                    adapter,
                    peripheral,
                    actual_id,
                    name,
                    cmd_char,
                )
                .await?;
                *session_slot().lock().await = Some(LegacyUpgradeDriver::DyjV1(sess));
                Ok(info)
            } else if let Some(gen1_char) = find_gen1_legacy_char(&chars) {
                let (sess, info) = DyjV1Gen1LegacySession::from_connected(
                    adapter,
                    peripheral,
                    actual_id,
                    name,
                    gen1_char,
                )
                .await?;
                *session_slot().lock().await = Some(LegacyUpgradeDriver::DyjV1Gen1(sess));
                Ok(info)
            } else {
                let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
                Err(BridgeError::from(
                    "未找到点一机控制特征 (FF11 或 2A29)，请确认设备状态".to_string(),
                ))
            }
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

pub(crate) async fn run_ota(
    payload: &Value,
    emit: &(dyn Fn(Value) + Send + Sync),
) -> Result<Value, BridgeError> {
    let driver = session_slot()
        .lock()
        .await
        .clone()
        .ok_or_else(|| BridgeError::from("旧固件升级会话未打开".to_string()))?;
    let res = driver.run_ota(payload, emit).await;
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

    #[test]
    fn gen1_json_assembler_handles_split_utf8_and_concatenated_objects() {
        let mut asm = Gen1JsonAssembler::default();
        let pkt = r#"noise{"name":"infoGet","content":{"ssid":"办公-{楼}"}}{"name":"updateState","content":{"state":"downloading"}}"#
            .as_bytes();
        // Split cleanly inside the multi-byte UTF-8 sequence for "办"
        let utf8_pos = pkt.iter().position(|&b| b >= 0x80).unwrap();
        let mid = utf8_pos + 1;
        let first = asm.feed(&pkt[..mid]);
        assert!(first.is_empty());
        let second = asm.feed(&pkt[mid..]);
        assert_eq!(second.len(), 2);
        let m1 = parse_gen1_response(&second[0]).unwrap();
        assert_eq!(m1.name.as_deref(), Some("infoGet"));
        assert_eq!(m1.content["ssid"], "办公-{楼}");
        let m2 = parse_gen1_response(&second[1]).unwrap();
        assert_eq!(m2.name.as_deref(), Some("updateState"));
        assert_eq!(m2.content["state"], "downloading");
    }

    #[test]
    fn builds_gen1_wire_requests_and_parses_failures() {
        let spec = TargetOtaSpec {
            version_name: "0.8.15".to_string(),
            version_code: 815,
            url: "https://hdd.dev.reai.com/ota/dyj1/app-815.apk".to_string(),
        };
        let bytes = build_gen1_update_app_request(&spec);
        let wire: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(wire["name"], "updateApp");
        let args_str = wire["arguments"].as_str().expect("arguments must be JSON string");
        let args: Value = serde_json::from_str(args_str).unwrap();
        assert_eq!(args["versionCode"], json!("815"));
        assert_eq!(args["force"], json!(true));
        assert_eq!(args["url"], json!("https://hdd.dev.reai.com/ota/dyj1/app-815.apk"));

        assert!(is_gen1_failure(&json!({"key": "network", "data": {"networkType": "WIFI"}})).is_none());
        assert_eq!(
            is_gen1_failure(&json!({"code": 1, "message": "密码错误"})).as_deref(),
            Some("密码错误")
        );
        assert_eq!(
            is_gen1_failure(&json!({"success": false, "error": "电量不足"})).as_deref(),
            Some("电量不足")
        );
    }

    #[test]
    fn aggregates_gen1_wifi_and_parses_target_ota_manifest() {
        let items = vec![
            json!({"index": 0, "size": 2, "item": {"ssid": "Guest", "signalStrength": -78, "isConnected": false}}),
            json!({"index": 1, "size": 2, "item": {"ssid": "Office", "signalStrength": -45, "isConnected": true}}),
        ];
        let agg = aggregate_gen1_wifi_networks(&items);
        assert_eq!(agg["currentSsid"], "Office");
        let nets = agg["networks"].as_array().unwrap();
        assert_eq!(nets[0]["ssid"], "Office");
        assert_eq!(nets[0]["connected"], true);
        assert_eq!(nets[0]["secure"], true);

        let parsed = parse_target_ota_spec(&json!({
            "targetOta": {
                "versionName": "0.8.16",
                "versionCode": 816,
                "url": "https://hdd.dev.reai.com/ota/dyj1/app-816.apk"
            }
        }))
        .unwrap();
        assert_eq!(parsed.version_code, 816);
        assert_eq!(parsed.version_name, "0.8.16");
        assert!(parse_target_ota_spec(&json!({})).is_none());
    }

    #[test]
    fn selects_post_upgrade_candidate_across_name_and_id_rotation() {
        let baseline: HashSet<String> = ["DYJ_OLDOTHER".to_string()].into_iter().collect();
        let candidates = vec![
            ("id-other".to_string(), "DYJ_OLDOTHER".to_string()),
            ("id-new".to_string(), "DYJ_NEW999".to_string()),
        ];
        let picked = select_post_upgrade_candidate(&candidates, "id-gen1", "DYJ-AB12CD", &baseline)
            .expect("should pick newly appeared DYJ_");
        assert_eq!(picked.0, "id-new");
        assert_eq!(picked.1, "DYJ_NEW999");

        let same_id = vec![
            ("id-other".to_string(), "DYJ_OLDOTHER".to_string()),
            ("id-gen1".to_string(), "DYJ_RENAMED".to_string()),
        ];
        let picked_id = select_post_upgrade_candidate(&same_id, "id-gen1", "DYJ-AB12CD", &baseline)
            .expect("should prefer same peripheral id");
        assert_eq!(picked_id.0, "id-gen1");
    }
}
