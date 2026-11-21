//! 讯飞智能录音笔 A1（ATS2837）Phase 1 只读硬件摸底探针。
//!
//! 严格约束：
//! - 全程只读（不向任何未知 GATT 特征写入数据，不打开已被占用的串口，不连接旁侧自研或其它第三方设备）。
//! - 广播名前缀匹配严格采用 UTF-8 字符安全逻辑，严禁按字节下标切片。
//!
//! 用法：
//!   cargo run --manifest-path app/rust/card_bridge/Cargo.toml --example iflytek_a1_probe -- usb [--out <json>]
//!   cargo run --manifest-path app/rust/card_bridge/Cargo.toml --example iflytek_a1_probe -- scan [--secs 10] [--all] [--match <substr>] [--out <json>]
//!   cargo run --manifest-path app/rust/card_bridge/Cargo.toml --example iflytek_a1_probe -- dump [--secs 10] [--id <id>] [--match <substr>] [--out <json>]
//!   cargo run --manifest-path app/rust/card_bridge/Cargo.toml --example iflytek_a1_probe -- listen [--secs 30] [--id <id>] [--match <substr>] [--out <json>]

use std::collections::{BTreeMap, HashSet};
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use btleplug::api::{
    Central, CentralEvent, CharPropFlags, Characteristic, Manager as _, Peripheral as _,
    ScanFilter,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use serde_json::{json, Value};
use uuid::Uuid;

const DEFAULT_SCAN_SECS: u64 = 10;
const DEFAULT_LISTEN_SECS: u64 = 30;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const DISCOVER_TIMEOUT: Duration = Duration::from_secs(15);
const READ_TIMEOUT: Duration = Duration::from_secs(3);
const DISCONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// 返回是否属于本项目既有自研或其他已接入第三方设备（严禁探针误连或写入）。
pub fn is_protected_other_device(name: &str) -> bool {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return false;
    }
    if trimmed == "录音豆" || trimmed.starts_with("飞书录音豆") {
        return true;
    }
    let upper = trimmed.to_ascii_uppercase();
    upper.starts_with("DYJV2")
        || upper.starts_with("DYJ_")
        || upper == "DYJ"
        || upper.starts_with("DYJ")
        || upper.starts_with("DFU_DYJ")
        || upper.starts_with("REAI_VB_")
        || upper == "OMI"
        || upper.starts_with("OMI-")
        || upper.starts_with("OMI_")
        || upper.starts_with("OMI ")
        || upper == "FRIEND"
        || upper.starts_with("FRIEND_")
        || upper.starts_with("FRIEND ")
        || upper.starts_with("D3200")
        || upper == "SOUNDCORE WORK"
        || upper.starts_with("SOUNDCORE WORK ")
        || upper.starts_with("GET-")
}

/// UTF-8 安全匹配讯飞录音笔 A1 广播名称（优先拦截保护设备）。
pub fn matches_iflytek_a1_name(name: &str, extra_match: Option<&str>) -> bool {
    let trimmed = name.trim();
    if trimmed.is_empty() || is_protected_other_device(trimmed) {
        return false;
    }
    let lower = trimmed.to_lowercase();
    if trimmed.starts_with("讯飞录音笔A1") || lower.starts_with("讯飞录音笔a1") {
        return true;
    }
    if let Some(extra) = extra_match.map(str::trim).filter(|s| !s.is_empty()) {
        return lower.contains(&extra.to_lowercase());
    }
    false
}

/// UTF-8 安全剥离 `讯飞录音笔A1_` / `讯飞录音笔A1-` 前缀提取尾号。
pub fn extract_a1_short_id(name: &str) -> Option<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() || is_protected_other_device(trimmed) {
        return None;
    }
    let lower = trimmed.to_lowercase();
    const PREFIX: &str = "讯飞录音笔a1";
    if !lower.starts_with(PREFIX) {
        return None;
    }
    let prefix_chars = "讯飞录音笔A1".chars().count();
    let tail: String = trimmed.chars().skip(prefix_chars).collect();
    let cleaned = tail.trim_start_matches(['_', '-', ' ']).trim();
    if cleaned.is_empty() {
        None
    } else {
        Some(cleaned.to_string())
    }
}

/// 识别标准 Bluetooth SIG 16-bit UUID（`0000xxxx-0000-1000-8000-00805f9b34fb`）并返回可读名。
pub fn standard_gatt_name(uuid: Uuid) -> Option<&'static str> {
    let raw = uuid.as_u128();
    const BASE_MASK: u128 = 0x0000_0000_ffff_ffff_ffff_ffff_ffff_ffff;
    const SIG_BASE: u128 = 0x0000_0000_0000_1000_8000_0080_5f9b_34fb;
    if (raw & BASE_MASK) != SIG_BASE {
        return None;
    }
    let short = ((raw >> 96) & 0xffff) as u16;
    match short {
        0x1800 => Some("Generic Access (GAP)"),
        0x1801 => Some("Generic Attribute (GATT)"),
        0x180A => Some("Device Information (DIS)"),
        0x180F => Some("Battery Service (BAS)"),
        0xFE59 => Some("Nordic Secure DFU"),
        0x2A00 => Some("Device Name"),
        0x2A01 => Some("Appearance"),
        0x2A04 => Some("Peripheral Preferred Connection Parameters"),
        0x2A05 => Some("Service Changed"),
        0x2A19 => Some("Battery Level"),
        0x2A23 => Some("System ID"),
        0x2A24 => Some("Model Number String"),
        0x2A25 => Some("Serial Number String"),
        0x2A26 => Some("Firmware Revision String"),
        0x2A27 => Some("Hardware Revision String"),
        0x2A28 => Some("Software Revision String"),
        0x2A29 => Some("Manufacturer Name String"),
        0x2A50 => Some("PnP ID"),
        0x2900 => Some("Characteristic Extended Properties"),
        0x2901 => Some("Characteristic User Description"),
        0x2902 => Some("Client Characteristic Configuration (CCCD)"),
        0x2904 => Some("Characteristic Presentation Format"),
        _ => None,
    }
}

fn hex_string(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn printable_utf8_preview(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) if s.chars().all(|c| !c.is_control() || c == '\n' || c == '\r' || c == '\t') => {
            s.to_string()
        }
        _ => bytes
            .iter()
            .map(|&b| {
                if (0x20..=0x7e).contains(&b) {
                    b as char
                } else {
                    '.'
                }
            })
            .collect(),
    }
}

fn format_props(flags: CharPropFlags) -> Vec<&'static str> {
    let mut out = Vec::new();
    if flags.contains(CharPropFlags::BROADCAST) {
        out.push("BROADCAST");
    }
    if flags.contains(CharPropFlags::READ) {
        out.push("READ");
    }
    if flags.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE) {
        out.push("WRITE_WITHOUT_RESPONSE");
    }
    if flags.contains(CharPropFlags::WRITE) {
        out.push("WRITE");
    }
    if flags.contains(CharPropFlags::NOTIFY) {
        out.push("NOTIFY");
    }
    if flags.contains(CharPropFlags::INDICATE) {
        out.push("INDICATE");
    }
    if flags.contains(CharPropFlags::AUTHENTICATED_SIGNED_WRITES) {
        out.push("AUTHENTICATED_SIGNED_WRITES");
    }
    if flags.contains(CharPropFlags::EXTENDED_PROPERTIES) {
        out.push("EXTENDED_PROPERTIES");
    }
    out
}

fn unix_ms_now() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

#[derive(Debug, Clone)]
struct CliArgs {
    command: String,
    secs: u64,
    all: bool,
    id: Option<String>,
    extra_match: Option<String>,
    out: Option<String>,
}

fn parse_cli() -> Result<CliArgs, String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        return Err(usage_text().to_string());
    }
    let command = args[0].clone();
    let default_secs = if command == "listen" {
        DEFAULT_LISTEN_SECS
    } else {
        DEFAULT_SCAN_SECS
    };
    let mut out = CliArgs {
        command,
        secs: default_secs,
        all: false,
        id: None,
        extra_match: None,
        out: None,
    };
    let mut i = 1usize;
    while i < args.len() {
        match args[i].as_str() {
            "--all" => {
                out.all = true;
                i += 1;
            }
            "--secs" => {
                let v = args.get(i + 1).ok_or("--secs 缺少秒数参数")?;
                out.secs = v
                    .parse::<u64>()
                    .map_err(|e| format!("无效的 --secs 参数 {v}: {e}"))?
                    .max(1);
                i += 2;
            }
            "--id" => {
                let v = args.get(i + 1).ok_or("--id 缺少设备 ID 参数")?;
                out.id = Some(v.clone());
                i += 2;
            }
            "--match" => {
                let v = args.get(i + 1).ok_or("--match 缺少匹配子串参数")?;
                out.extra_match = Some(v.clone());
                i += 2;
            }
            "--out" => {
                let v = args.get(i + 1).ok_or("--out 缺少输出文件路径")?;
                out.out = Some(v.clone());
                i += 2;
            }
            other => return Err(format!("未知参数: {other}\n\n{}", usage_text())),
        }
    }
    Ok(out)
}

fn usage_text() -> &'static str {
    "用法:\n  iflytek_a1_probe usb [--out <json>]\n  iflytek_a1_probe scan [--secs 10] [--all] [--match <substr>] [--out <json>]\n  iflytek_a1_probe dump [--secs 10] [--id <id>] [--match <substr>] [--out <json>]\n  iflytek_a1_probe listen [--secs 30] [--id <id>] [--match <substr>] [--out <json>]"
}

#[derive(Clone)]
struct ScannedDevice {
    peripheral: Peripheral,
    id: String,
    local_name: String,
    advertisement_name: String,
    rssi: Option<i16>,
    services: Vec<Uuid>,
    manufacturer_data: BTreeMap<u16, Vec<u8>>,
    service_data: BTreeMap<Uuid, Vec<u8>>,
    advertised_in_window: bool,
    is_protected: bool,
    is_candidate: bool,
}

impl ScannedDevice {
    fn best_name(&self) -> &str {
        if !self.local_name.is_empty() {
            &self.local_name
        } else {
            &self.advertisement_name
        }
    }

    fn to_json(&self) -> Value {
        let name = self.best_name();
        let mfd_json: BTreeMap<String, String> = self
            .manufacturer_data
            .iter()
            .map(|(k, v)| (format!("0x{k:04x}"), hex_string(v)))
            .collect();
        let svc_data_json: BTreeMap<String, String> = self
            .service_data
            .iter()
            .map(|(k, v)| (k.to_string(), hex_string(v)))
            .collect();
        let svcs: Vec<String> = self.services.iter().map(Uuid::to_string).collect();
        json!({
            "id": self.id,
            "localName": name,
            "advertisementName": self.advertisement_name,
            "localNameUtf8Hex": hex_string(name.as_bytes()),
            "shortId": extract_a1_short_id(name),
            "rssi": self.rssi,
            "advertisedInWindow": self.advertised_in_window,
            "isIflytekCandidate": self.is_candidate,
            "isProtectedOther": self.is_protected,
            "services": svcs,
            "manufacturerDataHex": mfd_json,
            "serviceDataHex": svc_data_json,
        })
    }
}

async fn ble_adapter() -> Result<Adapter, Box<dyn std::error::Error>> {
    let manager = Manager::new().await?;
    let adapters = manager.adapters().await?;
    adapters
        .into_iter()
        .next()
        .ok_or_else(|| "未发现可用 BLE 蓝牙适配器".into())
}

async fn scan_ble_window(
    adapter: &Adapter,
    secs: u64,
    extra_match: Option<&str>,
) -> Result<Vec<ScannedDevice>, Box<dyn std::error::Error>> {
    let mut events = adapter.events().await?;
    let mut seen: HashSet<String> = HashSet::new();
    adapter.start_scan(ScanFilter::default()).await?;
    let pump = async {
        while let Some(ev) = events.next().await {
            let id = match ev {
                CentralEvent::DeviceDiscovered(id)
                | CentralEvent::DeviceUpdated(id)
                | CentralEvent::ManufacturerDataAdvertisement { id, .. }
                | CentralEvent::ServiceDataAdvertisement { id, .. }
                | CentralEvent::ServicesAdvertisement { id, .. } => id,
                _ => continue,
            };
            seen.insert(id.to_string());
        }
    };
    let _ = tokio::time::timeout(Duration::from_secs(secs), pump).await;
    let _ = adapter.stop_scan().await;

    let peripherals = adapter.peripherals().await?;
    let mut items = Vec::with_capacity(peripherals.len());
    for p in peripherals {
        let Ok(Some(props)) = p.properties().await else {
            continue;
        };
        let pid = p.id().to_string();
        let local_name = props
            .local_name
            .as_deref()
            .map(str::trim)
            .unwrap_or("")
            .to_string();
        let adv_name = props
            .advertisement_name
            .as_deref()
            .map(str::trim)
            .unwrap_or("")
            .to_string();
        let is_protected =
            is_protected_other_device(&local_name) || is_protected_other_device(&adv_name);
        let is_candidate = !is_protected
            && (matches_iflytek_a1_name(&local_name, extra_match)
                || matches_iflytek_a1_name(&adv_name, extra_match));

        let mfd: BTreeMap<u16, Vec<u8>> = props
            .manufacturer_data
            .iter()
            .map(|(k, v)| (*k, v.clone()))
            .collect();
        let sdata: BTreeMap<Uuid, Vec<u8>> = props
            .service_data
            .iter()
            .map(|(k, v)| (*k, v.clone()))
            .collect();

        items.push(ScannedDevice {
            peripheral: p,
            id: pid.clone(),
            local_name,
            advertisement_name: adv_name,
            rssi: props.rssi,
            services: props.services,
            manufacturer_data: mfd,
            service_data: sdata,
            advertised_in_window: seen.contains(&pid),
            is_protected,
            is_candidate,
        });
    }

    items.sort_by(|a, b| {
        b.is_candidate
            .cmp(&a.is_candidate)
            .then_with(|| b.advertised_in_window.cmp(&a.advertised_in_window))
            .then_with(|| b.rssi.unwrap_or(-120).cmp(&a.rssi.unwrap_or(-120)))
    });
    Ok(items)
}

fn select_target<'a>(
    items: &'a [ScannedDevice],
    target_id: Option<&str>,
) -> Result<&'a ScannedDevice, String> {
    if let Some(wanted) = target_id.map(str::trim).filter(|s| !s.is_empty()) {
        let found = items
            .iter()
            .find(|d| d.id.eq_ignore_ascii_case(wanted))
            .ok_or_else(|| format!("未在本次扫描中发现指定 ID 设备: {wanted}"))?;
        if found.is_protected {
            return Err(format!(
                "安全拦截：目标 ID={} 属于受保护的其他硬件（name={:?}），探针禁止连接",
                found.id,
                found.best_name()
            ));
        }
        return Ok(found);
    }

    items
        .iter()
        .find(|d| d.is_candidate && !d.is_protected)
        .ok_or_else(|| {
            let names: Vec<String> = items
                .iter()
                .filter(|d| d.advertised_in_window && !d.best_name().is_empty())
                .map(|d| format!("{:?} ({})", d.best_name(), d.id))
                .collect();
            format!(
                "未发现讯飞录音笔 A1 广播（确认已拔掉主机 USB 线并处于开机蓝灯闪烁态）。本次共见 {} 台设备，含名设备：{:?}",
                items.len(),
                names
            )
        })
}

async fn connect_and_discover(
    target: &ScannedDevice,
) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!(
        "[probe] 正在连接目标 A1: name={:?} id={} rssi={:?}",
        target.best_name(),
        target.id,
        target.rssi
    );
    if !target.peripheral.is_connected().await? {
        target
            .peripheral
            .connect_with_timeout(CONNECT_TIMEOUT)
            .await?;
    }
    target
        .peripheral
        .discover_services_with_timeout(DISCOVER_TIMEOUT)
        .await?;
    Ok(())
}

async fn read_characteristic_safely(p: &Peripheral, ch: &Characteristic) -> Value {
    match tokio::time::timeout(READ_TIMEOUT, p.read(ch)).await {
        Ok(Ok(bytes)) => {
            let mut obj = json!({
                "ok": true,
                "len": bytes.len(),
                "hex": hex_string(&bytes),
                "utf8Preview": printable_utf8_preview(&bytes),
            });
            if bytes.len() == 1 {
                obj["uint8Value"] = json!(bytes[0]);
            }
            obj
        }
        Ok(Err(err)) => json!({
            "ok": false,
            "error": err.to_string(),
        }),
        Err(_) => json!({
            "ok": false,
            "error": format!("read timeout ({}s)", READ_TIMEOUT.as_secs()),
        }),
    }
}

async fn cmd_scan(args: &CliArgs) -> Result<Value, Box<dyn std::error::Error>> {
    let adapter = ble_adapter().await?;
    let adapter_info = adapter.adapter_info().await.unwrap_or_default();
    let items = scan_ble_window(&adapter, args.secs, args.extra_match.as_deref()).await?;
    let candidate_count = items.iter().filter(|d| d.is_candidate).count();
    let selected: Vec<Value> = items
        .iter()
        .filter(|d| args.all || d.is_candidate)
        .map(ScannedDevice::to_json)
        .collect();
    let ignored_named: Vec<Value> = items
        .iter()
        .filter(|d| !args.all && !d.is_candidate && !d.best_name().is_empty())
        .map(|d| {
            json!({
                "id": d.id,
                "localName": d.best_name(),
                "rssi": d.rssi,
                "isProtectedOther": d.is_protected,
            })
        })
        .collect();

    Ok(json!({
        "command": "scan",
        "timestampMs": unix_ms_now(),
        "adapter": adapter_info,
        "scanSecs": args.secs,
        "showAll": args.all,
        "totalDiscovered": items.len(),
        "iflytekCandidateCount": candidate_count,
        "devices": selected,
        "ignoredNamedDevices": ignored_named,
    }))
}

async fn cmd_dump(args: &CliArgs) -> Result<Value, Box<dyn std::error::Error>> {
    let adapter = ble_adapter().await?;
    let items = scan_ble_window(&adapter, args.secs, args.extra_match.as_deref()).await?;
    let target = select_target(&items, args.id.as_deref())?;
    connect_and_discover(target).await?;

    let result = async {
        let services = target.peripheral.services();
        let mut service_list = Vec::with_capacity(services.len());
        for svc in services {
            let mut chars_json = Vec::with_capacity(svc.characteristics.len());
            for ch in &svc.characteristics {
                let descs: Vec<Value> = ch
                    .descriptors
                    .iter()
                    .map(|d| {
                        json!({
                            "uuid": d.uuid.to_string(),
                            "standardName": standard_gatt_name(d.uuid),
                        })
                    })
                    .collect();
                let read_result = if ch.properties.contains(CharPropFlags::READ) {
                    Some(read_characteristic_safely(&target.peripheral, ch).await)
                } else {
                    None
                };
                chars_json.push(json!({
                    "uuid": ch.uuid.to_string(),
                    "standardName": standard_gatt_name(ch.uuid),
                    "properties": format_props(ch.properties),
                    "descriptors": descs,
                    "readResult": read_result,
                }));
            }
            service_list.push(json!({
                "uuid": svc.uuid.to_string(),
                "standardName": standard_gatt_name(svc.uuid),
                "primary": svc.primary,
                "characteristics": chars_json,
            }));
        }

        let rssi_now = target.peripheral.read_rssi().await.ok();
        let conn_params = target
            .peripheral
            .connection_parameters()
            .await
            .ok()
            .flatten()
            .map(|cp| {
                json!({
                    "intervalUs": cp.interval_us,
                    "latency": cp.latency,
                    "supervisionTimeoutUs": cp.supervision_timeout_us,
                })
            });

        Ok::<Value, Box<dyn std::error::Error>>(json!({
            "command": "dump",
            "timestampMs": unix_ms_now(),
            "device": target.to_json(),
            "address": target.peripheral.address().to_string(),
            "mtu": target.peripheral.mtu(),
            "connectedRssi": rssi_now,
            "connectionParameters": conn_params,
            "serviceCount": service_list.len(),
            "services": service_list,
        }))
    }
    .await;

    let _ = tokio::time::timeout(DISCONNECT_TIMEOUT, target.peripheral.disconnect()).await;
    result
}

async fn cmd_listen(args: &CliArgs) -> Result<Value, Box<dyn std::error::Error>> {
    let adapter = ble_adapter().await?;
    let items = scan_ble_window(&adapter, DEFAULT_SCAN_SECS, args.extra_match.as_deref()).await?;
    let target = select_target(&items, args.id.as_deref())?;
    connect_and_discover(target).await?;

    let result = async {
        let mut notifications = target.peripheral.notifications().await?;
        let chars = target.peripheral.characteristics();
        let mut subscribed = Vec::new();
        let mut subscribe_errors = Vec::new();
        for ch in chars {
            if ch
                .properties
                .intersects(CharPropFlags::NOTIFY | CharPropFlags::INDICATE)
            {
                match target.peripheral.subscribe(&ch).await {
                    Ok(()) => subscribed.push(ch),
                    Err(err) => subscribe_errors.push(json!({
                        "uuid": ch.uuid.to_string(),
                        "error": err.to_string(),
                    })),
                }
            }
        }

        let subscribed_uuids: Vec<String> =
            subscribed.iter().map(|c| c.uuid.to_string()).collect();
        eprintln!(
            "[probe] 已订阅 {} 个通知特征，开始被动监听 {} 秒（可短按 A1 物理键观察上报）...",
            subscribed.len(),
            args.secs
        );

        let started = Instant::now();
        let deadline = tokio::time::sleep(Duration::from_secs(args.secs));
        tokio::pin!(deadline);
        let mut events = Vec::new();

        loop {
            tokio::select! {
                _ = &mut deadline => break,
                maybe_note = notifications.next() => {
                    let Some(note) = maybe_note else {
                        break;
                    };
                    let elapsed_ms = started.elapsed().as_millis();
                    let hex = hex_string(&note.value);
                    let ascii = printable_utf8_preview(&note.value);
                    eprintln!(
                        "[+{elapsed_ms}ms] notify uuid={} len={} hex={hex}",
                        note.uuid,
                        note.value.len()
                    );
                    events.push(json!({
                        "elapsedMs": elapsed_ms,
                        "serviceUuid": note.service_uuid.to_string(),
                        "uuid": note.uuid.to_string(),
                        "len": note.value.len(),
                        "hex": hex,
                        "asciiPreview": ascii,
                    }));
                }
            }
        }

        for ch in &subscribed {
            let _ = tokio::time::timeout(Duration::from_secs(2), target.peripheral.unsubscribe(ch))
                .await;
        }

        Ok::<Value, Box<dyn std::error::Error>>(json!({
            "command": "listen",
            "timestampMs": unix_ms_now(),
            "listenSecs": args.secs,
            "device": target.to_json(),
            "subscribedCharacteristics": subscribed_uuids,
            "subscribeErrors": subscribe_errors,
            "eventCount": events.len(),
            "events": events,
        }))
    }
    .await;

    let _ = tokio::time::timeout(DISCONNECT_TIMEOUT, target.peripheral.disconnect()).await;
    result
}

fn collect_actions_usb(node: &Value, path: &[String], out: &mut Vec<Value>) {
    let name = node
        .get("_name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let vendor_id = node.get("vendor_id").and_then(Value::as_str).unwrap_or("");
    let manufacturer = node
        .get("manufacturer")
        .and_then(Value::as_str)
        .unwrap_or("");
    let is_actions = vendor_id.to_ascii_lowercase().contains("0x10d7")
        || manufacturer.eq_ignore_ascii_case("Actions")
        || name.eq_ignore_ascii_case("CDC ACM");

    let mut next_path = path.to_vec();
    if !name.is_empty() {
        next_path.push(name.clone());
    }

    if is_actions {
        let mut entry = node.clone();
        if let Some(obj) = entry.as_object_mut() {
            obj.remove("_items");
            obj.insert("usbTreePath".to_string(), json!(next_path));
        }
        out.push(entry);
    }

    if let Some(children) = node.get("_items").and_then(Value::as_array) {
        for child in children {
            collect_actions_usb(child, &next_path, out);
        }
    }
}

fn list_dir_entries(dir: &str, prefix_filter: Option<&str>) -> Vec<String> {
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names: Vec<String> = rd
        .filter_map(Result::ok)
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|name| match prefix_filter {
            Some(p) => name.starts_with(p),
            None => true,
        })
        .map(|name| format!("{dir}/{name}"))
        .collect();
    names.sort();
    names
}

fn cmd_usb() -> Result<Value, Box<dyn std::error::Error>> {
    let os = env::consts::OS;
    if os != "macos" {
        return Ok(json!({
            "command": "usb",
            "timestampMs": unix_ms_now(),
            "platform": os,
            "supported": false,
            "note": "usb 子命令仅在 macOS 宿主机通过 system_profiler/diskutil 只读枚举",
        }));
    }

    let usb_out = Command::new("system_profiler")
        .args(["-json", "SPUSBDataType"])
        .output()?;
    if !usb_out.status.success() {
        return Err(format!(
            "system_profiler 执行失败: {}",
            String::from_utf8_lossy(&usb_out.stderr)
        )
        .into());
    }
    let usb_json: Value = serde_json::from_slice(&usb_out.stdout)?;
    let mut actions_devices = Vec::new();
    if let Some(buses) = usb_json.get("SPUSBDataType").and_then(Value::as_array) {
        for bus in buses {
            collect_actions_usb(bus, &[], &mut actions_devices);
        }
    }

    let serial_cu = list_dir_entries("/dev", Some("cu.usbmodem"));
    let serial_tty = list_dir_entries("/dev", Some("tty.usbmodem"));
    let volumes: Vec<String> = list_dir_entries("/Volumes", None)
        .into_iter()
        .filter(|v| v != "/Volumes/Macintosh HD")
        .collect();

    let diskutil_out = Command::new("diskutil")
        .args(["list", "external"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    Ok(json!({
        "command": "usb",
        "timestampMs": unix_ms_now(),
        "platform": os,
        "actionsUsbDevices": actions_devices,
        "serialNodes": {
            "cu": serial_cu,
            "tty": serial_tty,
        },
        "externalVolumes": volumes,
        "diskutilExternal": diskutil_out,
        "readOnlyNote": "仅执行只读总线与设备节点枚举，未打开或读写任何 /dev/* 串口",
    }))
}

fn write_json_output(out_path: Option<&str>, payload: &Value) -> Result<(), Box<dyn std::error::Error>> {
    let pretty = serde_json::to_string_pretty(payload)?;
    println!("{pretty}");
    if let Some(path_str) = out_path {
        let p = Path::new(path_str);
        if let Some(parent) = p.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent)?;
            }
        }
        fs::write(p, format!("{pretty}\n"))?;
        eprintln!("[probe] 已写入报告: {path_str}");
    }
    Ok(())
}

#[tokio::main]
async fn main() {
    let args = match parse_cli() {
        Ok(parsed) => parsed,
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(2);
        }
    };

    let res = match args.command.as_str() {
        "usb" => cmd_usb(),
        "scan" => cmd_scan(&args).await,
        "dump" => cmd_dump(&args).await,
        "listen" => cmd_listen(&args).await,
        other => Err(format!("未知子命令: {other}\n\n{}", usage_text()).into()),
    };

    match res {
        Ok(payload) => {
            if let Err(err) = write_json_output(args.out.as_deref(), &payload) {
                eprintln!("[probe] 输出 JSON 失败: {err}");
                std::process::exit(1);
            }
        }
        Err(err) => {
            eprintln!("[probe] 执行失败: {err}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_safe_iflytek_a1_name_matching_never_panics() {
        assert!(matches_iflytek_a1_name("讯飞录音笔A1_11E0", None));
        assert!(matches_iflytek_a1_name("  讯飞录音笔a1_abcd ", None));
        assert!(matches_iflytek_a1_name("讯飞录音笔A1", None));
        assert!(!matches_iflytek_a1_name("讯", None));
        assert!(!matches_iflytek_a1_name("讯飞", None));
        assert!(!matches_iflytek_a1_name("", None));
        assert!(matches_iflytek_a1_name("iFlytek-A1-Test", Some("iFlytek")));
    }

    #[test]
    fn extracts_a1_short_id_utf8_safely() {
        assert_eq!(
            extract_a1_short_id("讯飞录音笔A1_11E0").as_deref(),
            Some("11E0")
        );
        assert_eq!(
            extract_a1_short_id("讯飞录音笔A1-9A2F").as_deref(),
            Some("9A2F")
        );
        assert_eq!(extract_a1_short_id("讯飞录音笔A1"), None);
        assert_eq!(extract_a1_short_id("DYJV2_T4W25T"), None);
    }

    #[test]
    fn protected_devices_are_strictly_blocked_even_with_extra_match() {
        for protected in [
            "DYJV2_T4W25T",
            "DYJ_YKAUP3",
            "DFU_DYJ_0001",
            "REAI_VB_L3M8N1",
            "Omi",
            "Omi-7F20",
            "Friend_1234",
            "D3200-C3A1",
            "soundcore Work",
            "Get-A7769D",
            "录音豆",
            "飞书录音豆_01",
        ] {
            assert!(
                is_protected_other_device(protected),
                "expected protected: {protected}"
            );
            assert!(
                !matches_iflytek_a1_name(protected, Some(protected)),
                "must never match protected device: {protected}"
            );
        }
    }

    #[test]
    fn standard_sig_uuids_map_to_human_names() {
        let bas = Uuid::parse_str("0000180f-0000-1000-8000-00805f9b34fb").unwrap();
        let bat = Uuid::parse_str("00002a19-0000-1000-8000-00805f9b34fb").unwrap();
        let dis = Uuid::parse_str("0000180a-0000-1000-8000-00805f9b34fb").unwrap();
        let fw = Uuid::parse_str("00002a26-0000-1000-8000-00805f9b34fb").unwrap();
        let custom = Uuid::parse_str("19b10000-e8f2-537e-4f6c-d104768a1214").unwrap();

        assert_eq!(standard_gatt_name(bas), Some("Battery Service (BAS)"));
        assert_eq!(standard_gatt_name(bat), Some("Battery Level"));
        assert_eq!(standard_gatt_name(dis), Some("Device Information (DIS)"));
        assert_eq!(standard_gatt_name(fw), Some("Firmware Revision String"));
        assert_eq!(standard_gatt_name(custom), None);
    }
}
