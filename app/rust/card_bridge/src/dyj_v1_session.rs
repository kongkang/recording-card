//! 点一机 V1（`DYJ_*`）共享适配器直连会话：
//! - 复用统一扫描的 `btleplug::platform::Adapter`，优先从已缓存外设零重扫直连；
//! - 订阅 `FF12` 前检查 `CharPropFlags::NOTIFY`，避免 `< 0.8.0` 旧固件（`FF12` 无 Notify）导致 `btleplug` 永久挂死；
//! - 检测 `< 0.8.0` 旧固件时主动探测版本号并显式 `disconnect()` 释放单连接广播，返回可操作升级提示；
//! - 通过 `cmd_lock` 严格串行化 `FF11` 命令请求（遵循 `PROTOCOL.md §4` 并发约定）。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use btleplug::api::{
    Central as _, CentralEvent, CharPropFlags, Characteristic, Peripheral as _, ScanFilter,
    WriteType,
};
use btleplug::platform::{Adapter, Peripheral, PeripheralId};
use futures::stream::StreamExt;
use reai_dyj_sdk::audio::{self, AdpcmDecoder, AmrWbDecoder, PcmChunk};
use reai_dyj_sdk::error::{Result as SdkResult, SdkError};
use reai_dyj_sdk::protocol::{BinaryFrame, BinaryFrameAssembler, Frame, FrameAssembler, ProtocolInfo};
use reai_dyj_sdk::DeviceEvent;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, Mutex as AsyncMutex};

pub const COMMAND_UUID: &str = "0000ff11-0000-1000-8000-00805f9b34fb";
pub const DATA_UUID: &str = "0000ff12-0000-1000-8000-00805f9b34fb";
pub const LEGACY_GEN1_SERVICE_UUID: &str = "0000180a-0000-1000-8000-00805f9b34fb";
pub const LEGACY_GEN1_CHAR_UUID: &str = "00002a29-0000-1000-8000-00805f9b34fb";
pub const LEGACY_GEN1_ALT_CHAR_UUID: &str = "0000180e-0000-1000-8000-00805f9b34fb";
/// 订阅 notify 后到首笔写之间的最小间隔（`subscribe()` 已等蓝牙栈 CCCD ACK 返回，40ms 后立即发首包以避免落入 macOS LSTO=360ms 超时悬崖）。
const NOTIFY_SETTLE: Duration = Duration::from_millis(40);
const GATT_OP_TIMEOUT: Duration = Duration::from_secs(6);

fn epoch_ms_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub(crate) fn should_send_dyj_keepalive(
    now_ms: u64,
    last_io_ms: u64,
    last_attempt_ms: u64,
    interval_ms: u64,
) -> bool {
    now_ms.saturating_sub(last_io_ms) >= interval_ms
        && now_ms.saturating_sub(last_attempt_ms) >= interval_ms
}

/// 查找最早一代（`dyj-app-v1`，v0.5.x–v0.6.12）点一机自定义通信特征（优先 `0x2A29`，回退 `0x180E`）。
///
/// 要求同时具备 `NOTIFY` 和写属性，避免把标准蓝牙设备信息服务（DIS）中只读的 `0x2A29` 厂商名误判成初代固件。
pub fn find_gen1_legacy_char<'a>(
    chars: impl IntoIterator<Item = &'a Characteristic> + Clone,
) -> Option<Characteristic> {
    let has_rw_notify = |c: &Characteristic| {
        c.properties.contains(CharPropFlags::NOTIFY)
            && (c.properties.contains(CharPropFlags::WRITE)
                || c.properties.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE))
    };
    chars
        .clone()
        .into_iter()
        .find(|c| {
            c.uuid.to_string().eq_ignore_ascii_case(LEGACY_GEN1_CHAR_UUID) && has_rw_notify(c)
        })
        .or_else(|| {
            chars.into_iter().find(|c| {
                c.uuid
                    .to_string()
                    .eq_ignore_ascii_case(LEGACY_GEN1_ALT_CHAR_UUID)
                    && has_rw_notify(c)
            })
        })
        .cloned()
}

struct PendingMap(Mutex<HashMap<u64, mpsc::Sender<Frame>>>);

fn response_done(data: &Value) -> bool {
    data.get("more").and_then(Value::as_bool) != Some(true)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedAudioFilename {
    pub year: u32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub session: Option<String>,
    pub seq: Option<u32>,
}

/// 解析点一机 V1 录音文件名：`audio_YYYYMMDD-HHMMSS_<SESSION8>_<SEQ>.amr`（或旧命名 `audio_YYYYMMDD-HHMMSS.amr`）。
pub fn parse_dyj_audio_filename(name: &str) -> Option<ParsedAudioFilename> {
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let stem = base
        .strip_suffix(".amr")
        .or_else(|| base.strip_suffix(".AMR"))?;
    let rest = stem.strip_prefix("audio_")?;
    let mut parts = rest.split('_');
    let dt = parts.next()?;
    let (date_str, time_str) = dt.split_once('-')?;
    if date_str.len() != 8 || time_str.len() != 6 {
        return None;
    }
    let year = date_str[0..4].parse::<u32>().ok()?;
    let month = date_str[4..6].parse::<u32>().ok()?;
    let day = date_str[6..8].parse::<u32>().ok()?;
    let hour = time_str[0..2].parse::<u32>().ok()?;
    let minute = time_str[2..4].parse::<u32>().ok()?;
    let second = time_str[4..6].parse::<u32>().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let session = parts
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    let seq = parts.next().and_then(|s| s.parse::<u32>().ok());
    Some(ParsedAudioFilename {
        year,
        month,
        day,
        hour,
        minute,
        second,
        session,
        seq,
    })
}

fn extract_version_fields(val: &Value) -> Option<String> {
    for target in [Some(val), val.get("data")] {
        let Some(obj) = target else { continue };
        for key in ["version", "versionName", "app_version", "firmwareVersion"] {
            if let Some(s) = obj
                .get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// 解析旧版固件（`v0.7.x` `BASE_INFO:{}` 或 `v0.5/0.6.x` `infoGet(base)`）响应中的版本号。
pub fn parse_legacy_version_from_line(line: &str) -> Option<String> {
    let trimmed = line.trim();
    let json_part = trimmed
        .strip_prefix("BASE_INFO:")
        .or_else(|| trimmed.strip_prefix("CMD:"))
        .or_else(|| trimmed.strip_prefix("RSP:"))
        .unwrap_or(trimmed);
    let val: Value = serde_json::from_str(json_part).ok()?;
    if let Some(ver) = extract_version_fields(&val) {
        return Some(ver);
    }
    if let Some(content) = val.get("content") {
        match content {
            Value::String(s) => {
                if let Ok(inner) = serde_json::from_str::<Value>(s) {
                    if let Some(ver) = extract_version_fields(&inner) {
                        return Some(ver);
                    }
                }
            }
            other => {
                if let Some(ver) = extract_version_fields(other) {
                    return Some(ver);
                }
            }
        }
    }
    None
}

/// 判断收到的非标准帧是否为旧版固件（`< 0.8.0`）拒绝 `CMD:{...}` 的错误回包。
pub fn is_legacy_unknown_cmd_line(line: &str) -> bool {
    let trimmed = line.trim();
    if let Some(rest) = trimmed.strip_prefix("CMD:") {
        if let Ok(v) = serde_json::from_str::<Value>(rest) {
            if v.get("code").and_then(Value::as_i64) == Some(-1001) {
                return true;
            }
            if v.get("message")
                .and_then(Value::as_str)
                .is_some_and(|m| m.contains("未知命令"))
            {
                return true;
            }
        }
    }
    trimmed.contains("未知命令")
}

/// 从语义版本号（如 `0.8.15`、`v0.7.2`）推导整数版本码（如 `815`、`702`）。
pub fn version_code_from_semver(version: &str) -> u64 {
    let clean = version.trim().trim_start_matches('v').trim_start_matches('V');
    let core = clean.split(['-', '+', ' ']).next().unwrap_or("");
    let nums: Vec<u64> = core
        .split('.')
        .filter_map(|p| p.parse::<u64>().ok())
        .collect();
    match nums.as_slice() {
        [maj, min, pat, ..] => maj * 10_000 + min * 100 + pat,
        [maj, min] => maj * 10_000 + min * 100,
        [maj] => *maj,
        _ => 0,
    }
}

pub fn legacy_firmware_error(version: Option<&str>) -> String {
    match version.map(str::trim).filter(|s| !s.is_empty()) {
        Some(ver) => format!(
            "LEGACY_UPGRADE_REQUIRED|dyj_v1|{ver}|0.8.12|检测到点一机固件版本不兼容（当前 v{ver}），请配置 Wi-Fi 完成自动升级"
        ),
        None => "LEGACY_UPGRADE_REQUIRED|dyj_v1||0.8.12|检测到点一机旧版固件（低于 v0.8.0），请配置 Wi-Fi 完成自动升级"
            .to_string(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DyjTtsError {
    Unsupported { code: Option<u32>, message: String },
    Other(String),
}

/// 识别点一机 V1 `tts.speak` 的前向兼容错误：
/// `0.8.14` 等尚未内置 `tts.speak` 的固件按协议 §6 返回 `code=1001`（未知命令），
/// 归一为干净的 `Unsupported` 且绝不污染/断开当前 BLE 会话。
pub fn classify_tts_speak_error(err: &SdkError, fw_version: &str) -> DyjTtsError {
    let ver_label = if fw_version.trim().is_empty() {
        "unknown"
    } else {
        fw_version.trim()
    };
    match err {
        SdkError::Device { code, msg } => {
            let low = msg.to_ascii_lowercase();
            if *code == 1001
                || low.contains("unknown command")
                || low.contains("unsupported")
                || low.contains("not implemented")
                || msg.contains("未知命令")
                || msg.contains("不支持")
            {
                DyjTtsError::Unsupported {
                    code: Some(*code),
                    message: format!(
                        "unsupported: 点一机固件（v{ver_label}）暂不支持 tts.speak 语音播报（code={code}: {msg}）"
                    ),
                }
            } else {
                DyjTtsError::Other(err.to_string())
            }
        }
        other => DyjTtsError::Other(other.to_string()),
    }
}

/// 解码实时音频块中的 AMR-WB 帧序列（兼容 DTX SID mode 9 / SPEECH_LOST mode 14 / NO_DATA mode 15）。
pub fn decode_realtime_amr_wb_payload(amr: &mut AmrWbDecoder, payload: &[u8]) -> Vec<i16> {
    let mut samples = Vec::new();
    let mut rest = payload;
    while !rest.is_empty() {
        let mode = (rest[0] >> 3) as usize & 0x0F;
        let frame_len = if mode <= 8 {
            1 + audio::WB_PAYLOAD_BYTES[mode]
        } else if mode == 9 {
            6
        } else if mode == 14 || mode == 15 {
            1
        } else {
            break;
        };
        if rest.len() < frame_len {
            break;
        }
        let (one, remainder) = rest.split_at(frame_len);
        if mode <= 8 {
            if let Some(pcm) = amr.decode(one) {
                samples.extend(pcm);
            } else {
                samples.extend(std::iter::repeat_n(0i16, audio::AMR_WB_FRAME_SAMPLES));
            }
        } else {
            samples.extend(std::iter::repeat_n(0i16, audio::AMR_WB_FRAME_SAMPLES));
        }
        rest = remainder;
    }
    samples
}

/// 将 outgoing `FF11` 控制帧按 ≤180 字节切分（适配 BLE 4.2 DLE / macOS 515 MTU，单 PDU 发送避免多次 RTT 落入 LSTO=360ms 超时），
/// 并在 UTF-8 字符边界处截断。
pub(crate) fn split_ble_mtu20_chunks(bytes: &[u8]) -> Vec<&[u8]> {
    const MAX_CHUNK: usize = 180;
    if bytes.is_empty() {
        return Vec::new();
    }
    if bytes.len() <= MAX_CHUNK {
        return vec![bytes];
    }
    if let Ok(s) = std::str::from_utf8(bytes) {
        let mut out = Vec::with_capacity((bytes.len() / 160) + 1);
        let mut start = 0usize;
        while start < s.len() {
            let mut end = (start + MAX_CHUNK).min(s.len());
            while end > start && !s.is_char_boundary(end) {
                end -= 1;
            }
            if end == start {
                return bytes.chunks(MAX_CHUNK).collect();
            }
            out.push(&bytes[start..end]);
            start = end;
        }
        return out;
    }
    bytes.chunks(MAX_CHUNK).collect()
}

pub struct DyjV1Session {
    name: String,
    peripheral: Peripheral,
    cmd_char: Characteristic,
    pending: Arc<PendingMap>,
    next_id: AtomicU64,
    cmd_lock: AsyncMutex<()>,
    event_tx: broadcast::Sender<DeviceEvent>,
    audio_tx: broadcast::Sender<PcmChunk>,
    disconnected: Arc<AtomicBool>,
    last_io_ms: Arc<AtomicU64>,
    _keepalive: mpsc::Sender<()>,
}

impl DyjV1Session {
    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn peripheral(&self) -> &Peripheral {
        &self.peripheral
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<DeviceEvent> {
        self.event_tx.subscribe()
    }

    pub fn subscribe_audio(&self) -> broadcast::Receiver<PcmChunk> {
        self.audio_tx.subscribe()
    }

    pub async fn is_connected(&self) -> SdkResult<bool> {
        if self.disconnected.load(Ordering::SeqCst) {
            return Ok(false);
        }
        self.peripheral
            .is_connected()
            .await
            .map_err(|e| SdkError::Ble(e.to_string()))
    }

    pub async fn disconnect(&self) -> SdkResult<()> {
        self.disconnected.store(true, Ordering::SeqCst);
        let _ = self.event_tx.send(DeviceEvent::Disconnected);
        tokio::time::timeout(Duration::from_secs(4), self.peripheral.disconnect())
            .await
            .map_err(|_| SdkError::Timeout {
                command: "disconnect".into(),
                seconds: 4,
            })?
            .map_err(|e| SdkError::Ble(e.to_string()))
    }

    /// 连接点一机 V1（复用统一扫描适配器），自动规避 `< 0.8.0` FF12 无 Notify 死锁并完成 `proto.hello`。
    ///
    /// 优先通过 `unified_scan` 缓存的 `PeripheralId` 零重扫直连（解决点一机 V1 间歇广播静默窗口内盲扫 5s 超时），
    /// 若缓存命中旧 RPA 或 2.4GHz Wi-Fi 共存导致首连握手/写通道瞬断，自动清缓存按广播名重扫并重连一次。
    pub async fn connect(
        adapter: &Adapter,
        id_hint: &str,
        name: &str,
        cached_peripheral_id: Option<&PeripheralId>,
        connecting_slot: Option<&Mutex<Option<Peripheral>>>,
    ) -> std::result::Result<(Arc<Self>, Value), String> {
        let mut attempt_cached = cached_peripheral_id;
        let mut attempt_id = id_hint;
        for attempt in 0..5 {
            match Self::connect_once(
                adapter,
                attempt_id,
                name,
                attempt_cached,
                connecting_slot,
            )
            .await
            {
                Ok(res) => return Ok(res),
                Err(err)
                    if attempt < 4
                        && !err.starts_with("LEGACY_UPGRADE_REQUIRED|")
                        && !name.trim().is_empty() =>
                {
                    log::warn!(
                        "dyj_v1_session: 第 {} 轮连接 {name} 失败（{err}），0.8s 后清缓存重扫重试",
                        attempt + 1
                    );
                    attempt_cached = None;
                    attempt_id = "";
                    tokio::time::sleep(Duration::from_millis(800)).await;
                }
                Err(err) => return Err(err),
            }
        }
        unreachable!()
    }

    async fn connect_once(
        adapter: &Adapter,
        id_hint: &str,
        name: &str,
        cached_peripheral_id: Option<&PeripheralId>,
        connecting_slot: Option<&Mutex<Option<Peripheral>>>,
    ) -> std::result::Result<(Arc<Self>, Value), String> {
        struct SlotGuard<'a>(Option<&'a Mutex<Option<Peripheral>>>);
        impl Drop for SlotGuard<'_> {
            fn drop(&mut self) {
                if let Some(slot) = self.0 {
                    *slot.lock().unwrap() = None;
                }
            }
        }
        let _guard = SlotGuard(connecting_slot);

        let peripheral = Self::connect_peripheral_with_rescan(
            adapter,
            id_hint,
            name,
            cached_peripheral_id,
            connecting_slot,
        )
        .await?;

        let discover_res =
            tokio::time::timeout(Duration::from_secs(12), peripheral.discover_services()).await;
        let discover_err = match discover_res {
            Ok(Ok(())) => None,
            Ok(Err(e)) => Some(format!("{e}")),
            Err(_) => Some("12s timeout".to_string()),
        };
        if let Some(detail) = discover_err {
            let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
            return Err(format!("点一机 V1 服务发现失败（{detail}），请重试连接"));
        }

        let chars = peripheral.characteristics();
        let find_char = |uuid: &str| {
            chars
                .iter()
                .find(|c| c.uuid.to_string().eq_ignore_ascii_case(uuid))
                .cloned()
        };

        let Some(cmd_char) = find_char(COMMAND_UUID) else {
            if let Some(gen1_char) = find_gen1_legacy_char(&chars) {
                log::info!(
                    "dyj_v1_session: {name} 未找到 FF11，命中初代固件特征 ({})，探测版本后转入引导升级",
                    gen1_char.uuid
                );
                let ver = Self::probe_gen1_legacy_version(&peripheral, &gen1_char).await;
                let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
                return Err(legacy_firmware_error(ver.as_deref()));
            }
            let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
            return Err("未找到点一机控制特征 (FF11)，请确认设备状态".to_string());
        };
        if !cmd_char.properties.contains(CharPropFlags::NOTIFY) {
            let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
            return Err("点一机控制特征 (FF11) 不支持通知".to_string());
        }

        let notifications = match tokio::time::timeout(
            Duration::from_secs(5),
            peripheral.notifications(),
        )
        .await
        {
            Ok(Ok(stream)) => stream,
            _ => {
                let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
                return Err("建立点一机通知监听失败，请重试".to_string());
            }
        };

        match tokio::time::timeout(GATT_OP_TIMEOUT, peripheral.subscribe(&cmd_char)).await {
            Ok(Ok(())) => {}
            _ => {
                let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
                return Err("订阅点一机控制通道 (FF11) 失败，请重试".to_string());
            }
        }

        let data_char = find_char(DATA_UUID);
        let has_ff12_notify = match data_char {
            Some(ref dc) if dc.properties.contains(CharPropFlags::NOTIFY) => {
                match tokio::time::timeout(GATT_OP_TIMEOUT, peripheral.subscribe(dc)).await {
                    Ok(Ok(())) => true,
                    _ => {
                        let _ =
                            tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect())
                                .await;
                        return Err("订阅点一机音频数据通道 (FF12) 失败，请重试".to_string());
                    }
                }
            }
            Some(_) => {
                log::info!("dyj_v1_session: {name} FF12 无 Notify 属性，判定为旧版固件 (<0.8.0)");
                false
            }
            None => false,
        };

        tokio::time::sleep(NOTIFY_SETTLE).await;
        if !peripheral.is_connected().await.unwrap_or(true) {
            let _ = tokio::time::timeout(Duration::from_secs(2), peripheral.disconnect()).await;
            return Err("点一机建连后瞬断，正在重试".to_string());
        }

        let (frame_tx, mut frame_rx) = mpsc::channel::<String>(64);
        let (binary_tx, mut binary_rx) = mpsc::channel::<BinaryFrame>(256);
        let (legacy_tx, mut legacy_rx) = mpsc::channel::<String>(16);
        let (event_tx, _) = broadcast::channel(64);
        let (audio_tx, _) = broadcast::channel::<PcmChunk>(256);
        let pending: Arc<PendingMap> = Arc::new(PendingMap(Mutex::new(HashMap::new())));
        let (keep_tx, mut keep_rx) = mpsc::channel::<()>(1);
        let disconnected = Arc::new(AtomicBool::new(false));
        let last_io_ms = Arc::new(AtomicU64::new(epoch_ms_now()));

        // 1) BLE notify 原始字节拆包任务（FF11 文本帧 / FF12 二进制帧）
        {
            let last_io_notify = last_io_ms.clone();
            tokio::spawn(async move {
                let mut stream = notifications;
                let mut text_asm = FrameAssembler::default();
                let mut bin_asm = BinaryFrameAssembler::default();
                while let Some(note) = stream.next().await {
                    last_io_notify.store(epoch_ms_now(), Ordering::Relaxed);
                    let uuid = note.uuid.to_string().to_lowercase();
                    if uuid == DATA_UUID {
                        for bf in bin_asm.feed(&note.value) {
                            if binary_tx.send(bf).await.is_err() {
                                return;
                            }
                        }
                    } else {
                        let chunk = String::from_utf8_lossy(&note.value);
                        for line in text_asm.feed(&chunk) {
                            if frame_tx.send(line).await.is_err() {
                                return;
                            }
                        }
                    }
                }
            });
        }

        // 2) 文本帧路由任务（RSP → pending，EVT → broadcast，非标准行 → legacy_tx）
        {
            let pending_reader = pending.clone();
            let event_tx_reader = event_tx.clone();
            let disconnected_reader = disconnected.clone();
            tokio::spawn(async move {
                loop {
                    tokio::select! {
                        line = frame_rx.recv() => {
                            match line {
                                Some(line) => match Frame::decode(&line) {
                                    Some(Frame::Response { id, code, msg, data }) => {
                                        let done = response_done(&data);
                                        let sender = {
                                            let mut map = pending_reader.0.lock().unwrap();
                                            if done {
                                                map.remove(&id)
                                            } else {
                                                map.get(&id).cloned()
                                            }
                                        };
                                        if let Some(tx) = sender {
                                            let _ = tx.send(Frame::Response { id, code, msg, data }).await;
                                        }
                                    }
                                    Some(Frame::Event { evt, ts, data }) => {
                                        let _ = event_tx_reader.send(DeviceEvent::Event { evt, ts, data });
                                    }
                                    Some(Frame::Request { .. }) | None => {
                                        let _ = legacy_tx.try_send(line);
                                    }
                                },
                                None => {
                                    disconnected_reader.store(true, Ordering::SeqCst);
                                    pending_reader.0.lock().unwrap().clear();
                                    let _ = event_tx_reader.send(DeviceEvent::Disconnected);
                                    break;
                                }
                            }
                        }
                        _ = keep_rx.recv() => break,
                    }
                }
            });
        }

        // 3) 实时音频解码任务（AMR-WB 16kHz / ADPCM → 16kHz 单声道 PcmChunk）
        {
            let audio_tx_task = audio_tx.clone();
            tokio::spawn(async move {
                let mut amr = AmrWbDecoder::new();
                let mut adpcm = AdpcmDecoder::new();
                let mut last_seq: Option<u16> = None;
                while let Some(frame) = binary_rx.recv().await {
                    match frame.frame_type {
                        BinaryFrame::TYPE_REALTIME_AUDIO_AMR | BinaryFrame::TYPE_REALTIME_AUDIO => {}
                        _ => continue,
                    }
                    let discontinuous = match last_seq {
                        Some(last) => frame.seq != last.wrapping_add(1),
                        None => false,
                    };
                    last_seq = Some(frame.seq);
                    let mut samples = Vec::new();
                    if frame.frame_type == BinaryFrame::TYPE_REALTIME_AUDIO_AMR {
                        if discontinuous {
                            amr.reset();
                        }
                        samples = decode_realtime_amr_wb_payload(&mut amr, &frame.payload);
                    } else {
                        if discontinuous {
                            adpcm.reset();
                        }
                        adpcm.decode_chunk(&frame.payload, &mut samples);
                    }
                    if samples.is_empty() && !discontinuous {
                        continue;
                    }
                    let _ = audio_tx_task.send(PcmChunk {
                        samples,
                        sample_rate: audio::SAMPLE_RATE_HZ,
                        channels: audio::CHANNELS,
                        discontinuous,
                    });
                }
            });
        }

        let session = Arc::new(Self {
            name: name.to_string(),
            peripheral: peripheral.clone(),
            cmd_char,
            pending,
            next_id: AtomicU64::new(0),
            cmd_lock: AsyncMutex::new(()),
            event_tx,
            audio_tx,
            disconnected,
            last_io_ms,
            _keepalive: keep_tx,
        });

        // 4) 旧版固件 fast-fail：FF12 无 Notify 时直接探测 BASE_INFO 并在 2s 内返回明确提示与断开连接
        if !has_ff12_notify {
            let ver = Self::probe_legacy_version(&session, &mut legacy_rx).await;
            let _ = tokio::time::timeout(Duration::from_secs(3), session.disconnect()).await;
            return Err(legacy_firmware_error(ver.as_deref()));
        }

        // 5) proto.hello 握手（含一次首包丢失重试；同时监听旧版 `-1001 未知命令` 快速识别）
        let hello_res = Self::perform_hello(&session, &mut legacy_rx).await;
        let hello_data = match hello_res {
            Ok(data) => data,
            Err(err_msg) => {
                let _ = tokio::time::timeout(Duration::from_secs(3), session.disconnect()).await;
                return Err(err_msg);
            }
        };

        // 6) 3 秒连接态看门狗 + 60 秒 BLE 保活心跳（防点一机固件 180s STALE_LINK_TIMEOUT_MS 主动断链）
        {
            const DYJ_KEEPALIVE_INTERVAL_MS: u64 = 60_000;
            let weak = Arc::downgrade(&session);
            tokio::spawn(async move {
                let mut last_keepalive_attempt_ms: u64 = 0;
                loop {
                    tokio::time::sleep(Duration::from_secs(3)).await;
                    let Some(sess) = weak.upgrade() else {
                        break;
                    };
                    if sess.disconnected.load(Ordering::SeqCst) {
                        break;
                    }
                    match sess.peripheral.is_connected().await {
                        Ok(true) => {
                            let now = epoch_ms_now();
                            let last_io = sess.last_io_ms.load(Ordering::Relaxed);
                            if should_send_dyj_keepalive(
                                now,
                                last_io,
                                last_keepalive_attempt_ms,
                                DYJ_KEEPALIVE_INTERVAL_MS,
                            ) {
                                last_keepalive_attempt_ms = now;
                                let _ = sess.try_keepalive_echo().await;
                            }
                        }
                        Ok(false) => {
                            sess.disconnected.store(true, Ordering::SeqCst);
                            let _ = sess.event_tx.send(DeviceEvent::Disconnected);
                            break;
                        }
                        Err(_) => continue,
                    }
                }
            });
        }

        if let Some(slot) = connecting_slot {
            *slot.lock().unwrap() = None;
        }
        Ok((session, hello_data))
    }

    async fn peripheral_matches_target(
        p: &Peripheral,
        id_hint: &str,
        trimmed_name: &str,
    ) -> bool {
        if !id_hint.is_empty() && p.id().to_string() == id_hint {
            if trimmed_name.is_empty() {
                return true;
            }
            let props = tokio::time::timeout(Duration::from_millis(350), p.properties())
                .await
                .ok()
                .and_then(std::result::Result::ok)
                .flatten();
            if let Some(props) = props {
                if let Some(local) = props.local_name.as_deref().map(str::trim) {
                    if !local.is_empty() && local != trimmed_name {
                        return false;
                    }
                }
            }
            return true;
        }
        if trimmed_name.is_empty() {
            return false;
        }
        let props = tokio::time::timeout(Duration::from_millis(350), p.properties())
            .await
            .ok()
            .and_then(std::result::Result::ok)
            .flatten();
        props
            .and_then(|pr| pr.local_name)
            .as_deref()
            .map(str::trim)
            == Some(trimmed_name)
    }

    async fn try_connect_candidate(
        p: &Peripheral,
        name: &str,
        timeout: Duration,
        connecting_slot: Option<&Mutex<Option<Peripheral>>>,
    ) -> std::result::Result<(), String> {
        if let Some(slot) = connecting_slot {
            *slot.lock().unwrap() = Some(p.clone());
        }
        let res = tokio::time::timeout(timeout, p.connect()).await;
        match res {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => {
                if let Some(slot) = connecting_slot {
                    *slot.lock().unwrap() = None;
                }
                let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
                Err(format!("连接点一机 V1 {name} 失败: {e}"))
            }
            Err(_) => {
                if let Some(slot) = connecting_slot {
                    *slot.lock().unwrap() = None;
                }
                let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
                Err(format!("连接点一机 V1 {name} 超时，请确认设备在附近并已开机"))
            }
        }
    }

    async fn connect_peripheral_with_rescan(
        adapter: &Adapter,
        id_hint: &str,
        name: &str,
        cached_peripheral_id: Option<&PeripheralId>,
        connecting_slot: Option<&Mutex<Option<Peripheral>>>,
    ) -> std::result::Result<Peripheral, String> {
        let trimmed_name = name.trim();
        let mut last_err: Option<String> = None;
        let mut tried_id: Option<String> = None;

        // 1) 优先使用 unified_scan 缓存的精确 PeripheralId 零重扫直连（无需枚举 peripherals 或调 properties()，
        //    避免点一机 V1 间歇广播静默窗口内盲目重扫导致 5s 超时）。
        if let Some(pid) = cached_peripheral_id {
            tried_id = Some(pid.to_string());
            if let Ok(cached) = adapter.peripheral(pid).await {
                match Self::try_connect_candidate(
                    &cached,
                    name,
                    Duration::from_secs(5),
                    connecting_slot,
                )
                .await
                {
                    Ok(()) => return Ok(cached),
                    Err(e) => last_err = Some(e),
                }
            }
        }

        // 2) 向 CoreBluetooth 找回缓存 UUID / 系统已连 FF10 外设，按 id_hint 或广播名匹配直连。
        let mut query_services = Vec::new();
        if let Ok(u) = uuid::Uuid::parse_str("6e400001-b5a3-f393-e0a9-e50e24dcca9e") {
            query_services.push(u);
        }
        query_services.push(uuid::Uuid::from_u128(0x0000ff10_0000_1000_8000_00805f9b34fb));
        let id_hint_arr = [id_hint];
        let id_hints: &[&str] = if id_hint.is_empty() { &[] } else { &id_hint_arr };
        let retrieved = crate::retrieve_cached_or_connected_peripherals(
            adapter,
            id_hints,
            &query_services,
        )
        .await;

        if !id_hint.is_empty() && tried_id.as_deref() != Some(id_hint) {
            if let Ok(peripherals) = adapter.peripherals().await {
                if let Some(cached) = peripherals
                    .into_iter()
                    .find(|p| p.id().to_string() == id_hint)
                {
                    if Self::peripheral_matches_target(&cached, id_hint, trimmed_name).await {
                        match Self::try_connect_candidate(
                            &cached,
                            name,
                            Duration::from_secs(5),
                            connecting_slot,
                        )
                        .await
                        {
                            Ok(()) => return Ok(cached),
                            Err(e) => last_err = Some(e),
                        }
                    }
                }
            }
        }

        for cached in retrieved {
            let pid = cached.id().to_string();
            if pid == id_hint || tried_id.as_deref() == Some(pid.as_str()) {
                continue;
            }
            let is_conn = matches!(
                tokio::time::timeout(Duration::from_millis(350), cached.is_connected()).await,
                Ok(Ok(true))
            );
            if !is_conn {
                continue;
            }
            if Self::peripheral_matches_target(&cached, id_hint, trimmed_name).await {
                match Self::try_connect_candidate(
                    &cached,
                    name,
                    Duration::from_secs(4),
                    connecting_slot,
                )
                .await
                {
                    Ok(()) => return Ok(cached),
                    Err(e) => last_err = Some(e),
                }
            }
        }

        // 3) 兜底：仅当缓存未命中或直连失败（如 RPA 轮换）时，开启实时扫描等待广播同名设备再连。
        let mut events = adapter
            .events()
            .await
            .map_err(|e| format!("点一机蓝牙事件流失败: {e}"))?;
        let _ = adapter.start_scan(ScanFilter::default()).await;

        let scan_deadline = tokio::time::Instant::now() + Duration::from_millis(7500);
        let mut fresh: Option<Peripheral> = None;
        loop {
            let now = tokio::time::Instant::now();
            if now >= scan_deadline {
                break;
            }
            let rem = scan_deadline.saturating_duration_since(now);
            let ev = match tokio::time::timeout(rem, events.next()).await {
                Ok(Some(ev)) => ev,
                _ => break,
            };
            let id = match ev {
                CentralEvent::DeviceDiscovered(id)
                | CentralEvent::DeviceUpdated(id)
                | CentralEvent::ManufacturerDataAdvertisement { id, .. }
                | CentralEvent::ServiceDataAdvertisement { id, .. }
                | CentralEvent::ServicesAdvertisement { id, .. } => id,
                _ => continue,
            };
            if let Ok(p) = adapter.peripheral(&id).await {
                if Self::peripheral_matches_target(&p, "", trimmed_name).await {
                    fresh = Some(p);
                    break;
                }
            }
        }
        let _ = adapter.stop_scan().await;
        tokio::time::sleep(Duration::from_millis(60)).await;

        let Some(fresh_peripheral) = fresh else {
            return Err(last_err.unwrap_or_else(|| {
                format!("未在附近找到点一机 V1（{name}），请确认设备已开机且未被其他手机连接")
            }));
        };

        Self::try_connect_candidate(
            &fresh_peripheral,
            name,
            Duration::from_secs(6),
            connecting_slot,
        )
        .await?;
        Ok(fresh_peripheral)
    }

    async fn write_bytes(&self, bytes: &[u8]) -> SdkResult<()> {
        let write_type = if self.cmd_char.properties.contains(CharPropFlags::WRITE) {
            WriteType::WithResponse
        } else {
            WriteType::WithoutResponse
        };
        for chunk in split_ble_mtu20_chunks(bytes) {
            let res = tokio::time::timeout(
                Duration::from_secs(4),
                self.peripheral.write(&self.cmd_char, chunk, write_type),
            )
            .await
            .map_err(|_| SdkError::Timeout {
                command: "ble.write".into(),
                seconds: 4,
            })?;
            if let Err(e) = res {
                let msg = format!("{e}");
                let low = msg.to_ascii_lowercase();
                if low.contains("peripheral not found")
                    || low.contains("disconnected")
                    || low.contains("not connected")
                    || low.contains("channel closed")
                {
                    if !self.disconnected.swap(true, Ordering::SeqCst) {
                        let _ = self.event_tx.send(DeviceEvent::Disconnected);
                    }
                }
                return Err(SdkError::Ble(format!("write FF11: {msg}")));
            }
        }
        self.last_io_ms.store(epoch_ms_now(), Ordering::Relaxed);
        Ok(())
    }

    async fn probe_gen1_legacy_version(
        peripheral: &Peripheral,
        ch: &Characteristic,
    ) -> Option<String> {
        let Ok(Ok(mut stream)) =
            tokio::time::timeout(Duration::from_secs(4), peripheral.notifications()).await
        else {
            return None;
        };
        match tokio::time::timeout(GATT_OP_TIMEOUT, peripheral.subscribe(ch)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                log::warn!(
                    "dyj_v1_session: 初代特征 ({}) subscribe 返回错误（继续尽力探测）: {e}",
                    ch.uuid
                );
            }
            Err(_) => {
                log::warn!("dyj_v1_session: 初代特征 ({}) subscribe 超时", ch.uuid);
                return None;
            }
        }
        tokio::time::sleep(Duration::from_millis(120)).await;

        let write_type = if ch.properties.contains(CharPropFlags::WRITE) {
            WriteType::WithResponse
        } else {
            WriteType::WithoutResponse
        };
        let req_bytes = crate::legacy_upgrade::build_gen1_request(
            "infoGet",
            &json!({ "key": "base" }),
        );
        if !matches!(
            tokio::time::timeout(Duration::from_secs(4), peripheral.write(ch, &req_bytes, write_type))
                .await,
            Ok(Ok(()))
        ) {
            return None;
        }

        let mut assembler = crate::legacy_upgrade::Gen1JsonAssembler::default();
        let deadline = tokio::time::Instant::now() + Duration::from_millis(1800);
        loop {
            let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
            if rem.is_zero() {
                return None;
            }
            match tokio::time::timeout(rem, stream.next()).await {
                Ok(Some(note)) => {
                    if note.uuid != ch.uuid {
                        continue;
                    }
                    for obj_str in assembler.feed(&note.value) {
                        if let Some(ver) = parse_legacy_version_from_line(&obj_str) {
                            return Some(ver);
                        }
                    }
                }
                _ => return None,
            }
        }
    }

    async fn probe_legacy_version(
        session: &DyjV1Session,
        legacy_rx: &mut mpsc::Receiver<String>,
    ) -> Option<String> {
        while let Ok(line) = legacy_rx.try_recv() {
            if let Some(ver) = parse_legacy_version_from_line(&line) {
                return Some(ver);
            }
        }
        if session.write_bytes(b"BASE_INFO:{}\r\n").await.is_err() {
            return None;
        }
        let deadline = tokio::time::Instant::now() + Duration::from_millis(1400);
        loop {
            let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
            if rem.is_zero() {
                return None;
            }
            match tokio::time::timeout(rem, legacy_rx.recv()).await {
                Ok(Some(line)) => {
                    if let Some(ver) = parse_legacy_version_from_line(&line) {
                        return Some(ver);
                    }
                }
                _ => return None,
            }
        }
    }

    async fn wait_legacy_unknown_cmd(legacy_rx: &mut mpsc::Receiver<String>) -> bool {
        while let Some(line) = legacy_rx.recv().await {
            if is_legacy_unknown_cmd_line(&line) {
                return true;
            }
        }
        false
    }

    async fn perform_hello(
        session: &DyjV1Session,
        legacy_rx: &mut mpsc::Receiver<String>,
    ) -> std::result::Result<Value, String> {
        for attempt in 0..2 {
            let params = json!({
                "name": "recording-card",
                "feature_bits": ProtocolInfo::FEATURE_HELLO
                    | ProtocolInfo::FEATURE_BINARY_TYPED_FRAMES
                    | ProtocolInfo::FEATURE_REALTIME_AUDIO,
                "auto_audio": false,
            });
            let req_fut = session.request("proto.hello", params, Duration::from_millis(2200));
            let legacy_fut = Self::wait_legacy_unknown_cmd(legacy_rx);
            let outcome = tokio::select! {
                res = req_fut => Some(res),
                is_legacy = legacy_fut => {
                    if is_legacy {
                        let ver = Self::probe_legacy_version(session, legacy_rx).await;
                        return Err(legacy_firmware_error(ver.as_deref()));
                    }
                    None
                }
            };
            match outcome {
                Some(Ok(data)) => return Ok(data),
                Some(Err(SdkError::Timeout { .. })) if attempt == 0 => {
                    continue;
                }
                Some(Err(SdkError::Device { code: 1001, .. })) => {
                    let ver = Self::probe_legacy_version(session, legacy_rx).await;
                    return Err(legacy_firmware_error(ver.as_deref()));
                }
                Some(Err(e)) => return Err(format!("点一机握手失败: {e}")),
                None => {
                    return Err("点一机连接已断开，请重试连接".to_string());
                }
            }
        }
        Err("点一机握手超时，请确认固件版本（需 v0.8.12+）并重试连接".to_string())
    }

    /// 严格串行化 `FF11` 命令请求（协议规则 §4）：等待前一条单帧或流式响应结束后才发下一条。
    pub async fn request(&self, cmd: &str, params: Value, timeout: Duration) -> SdkResult<Value> {
        if self.disconnected.load(Ordering::SeqCst) {
            return Err(SdkError::Disconnected {
                command: cmd.to_string(),
            });
        }
        let _guard = self.cmd_lock.lock().await;
        self.request_locked(cmd, params, timeout).await
    }

    async fn request_locked(&self, cmd: &str, params: Value, timeout: Duration) -> SdkResult<Value> {
        if self.disconnected.load(Ordering::SeqCst) {
            return Err(SdkError::Disconnected {
                command: cmd.to_string(),
            });
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, mut rx) = mpsc::channel::<Frame>(32);
        self.pending.0.lock().unwrap().insert(id, tx);

        let frame = Frame::Request {
            id,
            cmd: cmd.to_string(),
            params,
        };
        let encoded = frame.encode();
        if let Err(e) = self.write_bytes(encoded.as_bytes()).await {
            self.pending.0.lock().unwrap().remove(&id);
            return Err(e);
        }

        let t0 = std::time::Instant::now();
        let mut items: Vec<Value> = Vec::new();
        loop {
            let wait = if items.is_empty() {
                timeout.saturating_sub(t0.elapsed())
            } else {
                timeout
            };
            let reply = match tokio::time::timeout(wait, rx.recv()).await {
                Ok(Some(f)) => f,
                Ok(None) => {
                    self.pending.0.lock().unwrap().remove(&id);
                    return Err(SdkError::Disconnected {
                        command: cmd.to_string(),
                    });
                }
                Err(_) => {
                    self.pending.0.lock().unwrap().remove(&id);
                    if !self.peripheral.is_connected().await.unwrap_or(true) {
                        if !self.disconnected.swap(true, Ordering::SeqCst) {
                            let _ = self.event_tx.send(DeviceEvent::Disconnected);
                        }
                        return Err(SdkError::Disconnected {
                            command: cmd.to_string(),
                        });
                    }
                    return Err(SdkError::Timeout {
                        command: cmd.to_string(),
                        seconds: timeout.as_secs(),
                    });
                }
            };
            let Frame::Response { code, msg, data, .. } = reply else {
                self.pending.0.lock().unwrap().remove(&id);
                return Err(SdkError::InvalidFrame("unexpected frame type for id".into()));
            };
            if code != 0 {
                self.pending.0.lock().unwrap().remove(&id);
                return Err(SdkError::Device { code, msg });
            }
            if data.get("index").is_none() {
                self.pending.0.lock().unwrap().remove(&id);
                return Ok(data);
            }
            if let Some(entry) = data.get("entry") {
                items.push(entry.clone());
            }
            if response_done(&data) {
                self.pending.0.lock().unwrap().remove(&id);
                let total = data
                    .get("total")
                    .and_then(Value::as_u64)
                    .unwrap_or(items.len() as u64);
                return Ok(json!({ "total": total, "items": items }));
            }
        }
    }

    /// 轻量级非阻塞 BLE 保活心跳（不排队阻塞正常命令），防止固件 `STALE_LINK_TIMEOUT_MS` 主动断链。
    pub async fn try_keepalive_echo(&self) -> bool {
        if self.disconnected.load(Ordering::SeqCst) {
            return false;
        }
        let Ok(_guard) = self.cmd_lock.try_lock() else {
            return false;
        };
        self.request_locked("proto.echo", json!({ "message": "hb" }), Duration::from_secs(4))
            .await
            .is_ok()
    }

    pub async fn request_idem(
        &self,
        cmd: &str,
        params: Value,
        timeout: Duration,
    ) -> SdkResult<Value> {
        match self.request(cmd, params.clone(), timeout).await {
            Err(SdkError::Timeout { seconds, .. }) => {
                self.request(cmd, params, Duration::from_secs(seconds)).await
            }
            other => other,
        }
    }

    pub async fn device_info(&self, verbose: bool) -> SdkResult<Value> {
        self.request_idem(
            "device.info",
            json!({ "verbose": verbose }),
            Duration::from_secs(5),
        )
        .await
    }

    pub async fn battery(&self) -> SdkResult<Value> {
        self.request_idem("device.battery", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn storage(&self) -> SdkResult<Value> {
        self.request_idem("device.storage", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn record_status(&self) -> SdkResult<Value> {
        self.request_idem("record.status", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn record_start(
        &self,
        segment_min: Option<u64>,
        session: Option<&str>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(m) = segment_min {
            params.insert("segment_min".into(), json!(m));
        }
        if let Some(s) = session {
            params.insert("session".into(), json!(s));
        }
        self.request("record.start", Value::Object(params), Duration::from_secs(10))
            .await
    }

    pub async fn record_stop(&self) -> SdkResult<Value> {
        self.request("record.stop", json!({}), Duration::from_secs(10))
            .await
    }

    pub async fn record_list(&self) -> SdkResult<Value> {
        self.request_idem("record.list", json!({}), Duration::from_secs(12))
            .await
    }

    pub async fn record_delete(&self, name: &str) -> SdkResult<Value> {
        self.request(
            "record.delete",
            json!({ "name": name }),
            Duration::from_secs(10),
        )
        .await
    }

    pub async fn audio_capture_start(&self) -> SdkResult<Value> {
        self.request("audio.capture.start", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn audio_capture_stop(&self) -> SdkResult<Value> {
        self.request("audio.capture.stop", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn audio_stream_start(&self) -> SdkResult<Value> {
        self.request("audio.stream.start", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn audio_stream_stop(&self) -> SdkResult<Value> {
        self.request("audio.stream.stop", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn camera_status(&self) -> SdkResult<Value> {
        self.request_idem("camera.status", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn camera_list(&self) -> SdkResult<Value> {
        self.request_idem("camera.list", json!({}), Duration::from_secs(10))
            .await
    }

    pub async fn camera_capture(&self) -> SdkResult<Value> {
        self.request("camera.capture", json!({}), Duration::from_secs(10))
            .await
    }

    pub async fn camera_delete(&self, name: &str) -> SdkResult<Value> {
        self.request(
            "camera.delete",
            json!({ "name": name }),
            Duration::from_secs(5),
        )
        .await
    }

    pub async fn wifi_status(&self) -> SdkResult<Value> {
        self.request_idem("wifi.status", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn wifi_scan(&self) -> SdkResult<Value> {
        self.request_idem("wifi.scan", json!({}), Duration::from_secs(35))
            .await
    }

    pub async fn wifi_connect(
        &self,
        ssid: &str,
        password: Option<&str>,
        bssid: Option<&str>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        params.insert("ssid".into(), json!(ssid));
        if let Some(p) = password {
            params.insert("password".into(), json!(p));
        }
        if let Some(b) = bssid {
            params.insert("bssid".into(), json!(b));
        }
        self.request("wifi.connect", Value::Object(params), Duration::from_secs(45))
            .await
    }

    pub async fn wifi_forget(&self, ssid: Option<&str>) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(s) = ssid {
            params.insert("ssid".into(), json!(s));
        }
        self.request("wifi.forget", Value::Object(params), Duration::from_secs(10))
            .await
    }

    pub async fn upload_config_get(&self) -> SdkResult<Value> {
        self.request_idem("upload.config.get", json!({}), Duration::from_secs(10))
            .await
    }

    pub async fn upload_config_set(
        &self,
        url: Option<&str>,
        token: Option<&str>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(u) = url {
            params.insert("url".into(), json!(u));
        }
        if let Some(t) = token {
            params.insert("token".into(), json!(t));
        }
        self.request_idem(
            "upload.config.set",
            Value::Object(params),
            Duration::from_secs(12),
        )
        .await
    }

    pub async fn upload_start(&self, name: Option<&str>) -> SdkResult<Value> {
        let params = match name {
            Some(n) => json!({ "name": n }),
            None => json!({}),
        };
        self.request("upload.start", params, Duration::from_secs(10))
            .await
    }

    pub async fn upload_status(&self) -> SdkResult<Value> {
        self.request_idem("upload.status", json!({}), Duration::from_secs(10))
            .await
    }

    pub async fn ap_start(
        &self,
        ssid: Option<&str>,
        password: Option<&str>,
        allow_sta_drop: bool,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(s) = ssid {
            params.insert("ssid".into(), json!(s));
        }
        if let Some(p) = password {
            params.insert("password".into(), json!(p));
        }
        if allow_sta_drop {
            params.insert("allow_sta_drop".into(), json!(true));
        }
        self.request_idem("ap.start", Value::Object(params), Duration::from_secs(35))
            .await
    }

    pub async fn ap_stop(&self) -> SdkResult<Value> {
        self.request_idem("ap.stop", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn ap_status(&self) -> SdkResult<Value> {
        self.request_idem("ap.status", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn ota_check(&self) -> SdkResult<Value> {
        self.request_idem("ota.check", json!({}), Duration::from_secs(12))
            .await
    }

    pub async fn ota_config_get(&self) -> SdkResult<Value> {
        self.request_idem("ota.config.get", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn ota_config_set(&self, url: &str) -> SdkResult<Value> {
        self.request("ota.config.set", json!({ "url": url }), Duration::from_secs(5))
            .await
    }

    pub async fn ota_install(&self, confirm: bool) -> SdkResult<Value> {
        self.request(
            "ota.install",
            json!({ "confirm": confirm }),
            Duration::from_secs(5),
        )
        .await
    }

    pub async fn ota_status(&self) -> SdkResult<Value> {
        self.request_idem("ota.status", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn device_time(&self, epoch_ms: Option<i64>) -> SdkResult<Value> {
        let params = epoch_ms
            .map(|t| json!({ "epoch_ms": t }))
            .unwrap_or_else(|| json!({}));
        self.request("device.time", params, Duration::from_secs(10))
            .await
    }

    pub async fn device_reboot(&self, confirm: bool) -> SdkResult<Value> {
        self.request(
            "device.reboot",
            json!({ "confirm": confirm }),
            Duration::from_secs(8),
        )
        .await
    }

    pub async fn camera_record_start(
        &self,
        max_s: Option<u64>,
        segment_s: Option<u64>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(m) = max_s {
            params.insert("max_s".into(), json!(m));
        }
        if let Some(seg) = segment_s {
            params.insert("segment_s".into(), json!(seg));
        }
        self.request(
            "camera.record.start",
            Value::Object(params),
            Duration::from_secs(10),
        )
        .await
    }

    pub async fn camera_record_stop(&self) -> SdkResult<Value> {
        self.request("camera.record.stop", json!({}), Duration::from_secs(10))
            .await
    }

    pub async fn camera_record_status(&self) -> SdkResult<Value> {
        self.request_idem("camera.record.status", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn sensor_status(&self) -> SdkResult<Value> {
        self.request_idem("sensor.status", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn sensor_read(&self, types: Option<&[String]>) -> SdkResult<Value> {
        let params = types
            .filter(|ts| !ts.is_empty())
            .map(|ts| json!({ "types": ts }))
            .unwrap_or_else(|| json!({}));
        self.request("sensor.read", params, Duration::from_secs(6))
            .await
    }

    pub async fn sensor_stream_start(
        &self,
        types: Option<&[String]>,
        interval_ms: Option<u64>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(ts) = types.filter(|ts| !ts.is_empty()) {
            params.insert("types".into(), json!(ts));
        }
        if let Some(ms) = interval_ms {
            params.insert("interval_ms".into(), json!(ms));
        }
        self.request(
            "sensor.stream.start",
            Value::Object(params),
            Duration::from_secs(10),
        )
        .await
    }

    pub async fn sensor_stream_stop(&self) -> SdkResult<Value> {
        self.request("sensor.stream.stop", json!({}), Duration::from_secs(10))
            .await
    }

    pub async fn location_status(&self) -> SdkResult<Value> {
        self.request_idem("location.status", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn location_get(&self, timeout_s: Option<u64>) -> SdkResult<Value> {
        let params = timeout_s
            .map(|s| json!({ "timeout_s": s }))
            .unwrap_or_else(|| json!({}));
        self.request("location.get", params, Duration::from_secs(32))
            .await
    }

    pub async fn location_stream_start(&self, min_interval_s: Option<u64>) -> SdkResult<Value> {
        let params = min_interval_s
            .map(|s| json!({ "min_interval_s": s }))
            .unwrap_or_else(|| json!({}));
        self.request("location.stream.start", params, Duration::from_secs(5))
            .await
    }

    pub async fn location_stream_stop(&self) -> SdkResult<Value> {
        self.request("location.stream.stop", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn vibrator_once(
        &self,
        duration_ms: Option<u64>,
        amplitude: Option<u8>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(d) = duration_ms {
            params.insert("duration_ms".into(), json!(d));
        }
        if let Some(a) = amplitude {
            params.insert("amplitude".into(), json!(a));
        }
        self.request(
            "vibrator.once",
            Value::Object(params),
            Duration::from_secs(8),
        )
        .await
    }

    pub async fn vibrator_cancel(&self) -> SdkResult<Value> {
        self.request("vibrator.cancel", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn volume_get(&self) -> SdkResult<Value> {
        self.request_idem("volume.get", json!({}), Duration::from_secs(8))
            .await
    }

    pub async fn volume_set(&self, stream: &str, value: i64) -> SdkResult<Value> {
        self.request(
            "volume.set",
            json!({ "stream": stream, "value": value }),
            Duration::from_secs(8),
        )
        .await
    }

    pub async fn led_status(&self) -> SdkResult<Value> {
        let agg = self
            .request_idem("led.status", json!({}), Duration::from_secs(10))
            .await?;
        let mut items = agg["items"].as_array().cloned().unwrap_or_default();
        let meta = if items.is_empty() {
            json!({})
        } else {
            items.remove(0)
        };
        Ok(json!({
            "active": meta.get("active").cloned().unwrap_or(Value::Null),
            "claims": items,
            "total": agg["total"],
        }))
    }

    pub async fn asr_status(&self) -> SdkResult<Value> {
        self.request_idem("asr.status", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn asr_config_get(&self) -> SdkResult<Value> {
        self.request_idem("asr.config.get", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn asr_config_set(
        &self,
        attach: Option<bool>,
        partial: Option<bool>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(a) = attach {
            params.insert("attach".into(), json!(a));
        }
        if let Some(p) = partial {
            params.insert("partial".into(), json!(p));
        }
        self.request(
            "asr.config.set",
            Value::Object(params),
            Duration::from_secs(5),
        )
        .await
    }

    pub async fn asr_start(
        &self,
        mode: Option<&str>,
        partial: Option<bool>,
        max_s: Option<u32>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        if let Some(m) = mode {
            params.insert("mode".into(), json!(m));
        }
        if let Some(p) = partial {
            params.insert("partial".into(), json!(p));
        }
        if let Some(s) = max_s {
            params.insert("max_s".into(), json!(s));
        }
        self.request("asr.start", Value::Object(params), Duration::from_secs(22))
            .await
    }

    pub async fn asr_stop(&self) -> SdkResult<Value> {
        self.request("asr.stop", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn button_status(&self) -> SdkResult<Value> {
        self.request_idem("button.status", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn button_bind_get(&self) -> SdkResult<Value> {
        self.request_idem("button.bind.get", json!({}), Duration::from_secs(5))
            .await
    }

    pub async fn button_bind_set(&self, gesture: &str, action: &str) -> SdkResult<Value> {
        self.request_idem(
            "button.bind.set",
            json!({ "gesture": gesture, "action": action }),
            Duration::from_secs(5),
        )
        .await
    }

    /// 确保物理按键统一处于 `event_only`（由手机端解释手势行为，不触发固件本地自停录）。
    pub async fn ensure_buttons_event_only(&self) -> bool {
        for attempt in 0..2 {
            if self.disconnected.load(Ordering::SeqCst) {
                return false;
            }
            if let Ok(current) = self.button_bind_get().await {
                let bindings = current.get("bindings");
                let mut all_ok = true;
                for gesture in ["click", "double_click", "long_press"] {
                    let cur = bindings.and_then(|b| b.get(gesture)).and_then(Value::as_str);
                    if cur != Some("event_only") {
                        if let Err(err) = self.button_bind_set(gesture, "event_only").await {
                            log::warn!(
                                "dyj_v1_session: {} ensure_buttons_event_only failed for {gesture}: {err}",
                                self.name
                            );
                            all_ok = false;
                        }
                    }
                }
                if all_ok {
                    return true;
                }
            } else {
                log::warn!(
                    "dyj_v1_session: {} button.bind.get failed (attempt {})",
                    self.name,
                    attempt + 1
                );
            }
            if attempt == 0 && !self.disconnected.load(Ordering::SeqCst) {
                tokio::time::sleep(Duration::from_millis(1200)).await;
            }
        }
        false
    }

    pub async fn led_set(
        &self,
        pattern: &str,
        brightness: Option<&str>,
        priority: Option<u32>,
        timeout_s: Option<u64>,
    ) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        params.insert("pattern".into(), json!(pattern));
        if let Some(b) = brightness {
            params.insert("brightness".into(), json!(b));
        }
        if let Some(p) = priority {
            params.insert("priority".into(), json!(p));
        }
        if let Some(t) = timeout_s {
            params.insert("timeout_s".into(), json!(t));
        }
        self.request_idem("led.set", Value::Object(params), Duration::from_secs(5))
            .await
    }

    pub async fn led_clear(&self) -> SdkResult<Value> {
        self.request_idem("led.clear", json!({}), Duration::from_secs(5))
            .await
    }

    /// 前向兼容调用点一机 V1 `tts.speak`（如未来固件内置端侧 TTS 扬声器播报）。
    /// 在 `0.8.14` 等尚未实现的固件上，设备按协议返回 `code=1001`（未知命令），由调用方映射为干净的 `unsupported` 错误。
    pub async fn tts_speak(&self, text: &str, interrupt: Option<bool>) -> SdkResult<Value> {
        let mut params = serde_json::Map::new();
        params.insert("text".into(), json!(text));
        if let Some(intr) = interrupt {
            params.insert("interrupt".into(), json!(intr));
        }
        self.request("tts.speak", Value::Object(params), Duration::from_secs(8))
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_legacy_unknown_cmd_and_version_lines() {
        let err_line = r#"CMD:{"code":-1001,"message":"未知命令: CMD"}"#;
        assert!(is_legacy_unknown_cmd_line(err_line));
        assert!(!is_legacy_unknown_cmd_line(r#"RSP:{"id":1,"code":0,"msg":"ok","data":{}}"#));

        let info_line =
            r#"BASE_INFO:{"version":"0.7.2","versionCode":702,"deviceId":"C5F96AD5895ADF02"}"#;
        assert_eq!(parse_legacy_version_from_line(info_line), Some("0.7.2".to_string()));
        let msg = legacy_firmware_error(Some("0.7.2"));
        assert!(msg.starts_with("LEGACY_UPGRADE_REQUIRED|dyj_v1|0.7.2|0.8.12|"));
        assert!(msg.contains("v0.7.2"));

        let gen1_line = r#"{"name":"infoGet","content":{"key":"base","data":{"versionName":"0.6.12","versionCode":612}}}"#;
        assert_eq!(parse_legacy_version_from_line(gen1_line), Some("0.6.12".to_string()));

        let gen1_str_content = r#"{"name":"infoGet","content":"{\"key\":\"base\",\"data\":{\"versionName\":\"0.5.14\"}}"}"#;
        assert_eq!(
            parse_legacy_version_from_line(gen1_str_content),
            Some("0.5.14".to_string())
        );

        let dis_readonly = Characteristic {
            uuid: uuid::Uuid::parse_str(LEGACY_GEN1_CHAR_UUID).unwrap(),
            service_uuid: uuid::Uuid::parse_str(LEGACY_GEN1_SERVICE_UUID).unwrap(),
            properties: CharPropFlags::READ,
            descriptors: Default::default(),
        };
        let gen1_char = Characteristic {
            uuid: uuid::Uuid::parse_str(LEGACY_GEN1_CHAR_UUID).unwrap(),
            service_uuid: uuid::Uuid::parse_str(LEGACY_GEN1_SERVICE_UUID).unwrap(),
            properties: CharPropFlags::READ | CharPropFlags::WRITE | CharPropFlags::NOTIFY,
            descriptors: Default::default(),
        };
        assert!(find_gen1_legacy_char(&[dis_readonly.clone()]).is_none());
        assert_eq!(
            find_gen1_legacy_char(&[dis_readonly, gen1_char.clone()])
                .unwrap()
                .uuid,
            gen1_char.uuid
        );
    }

    #[test]
    fn parses_dyj_v1_audio_filenames() {
        let full = parse_dyj_audio_filename("audio_20261026-153000_A1B2C3D4_02.amr").unwrap();
        assert_eq!(full.year, 2026);
        assert_eq!(full.month, 10);
        assert_eq!(full.day, 26);
        assert_eq!(full.hour, 15);
        assert_eq!(full.minute, 30);
        assert_eq!(full.second, 0);
        assert_eq!(full.session.as_deref(), Some("A1B2C3D4"));
        assert_eq!(full.seq, Some(2));

        let legacy = parse_dyj_audio_filename("files/audio/audio_20261116-091530.amr").unwrap();
        assert_eq!(legacy.session, None);
        assert_eq!(legacy.seq, None);
        assert_eq!(legacy.hour, 9);

        assert!(parse_dyj_audio_filename("AUDIO_001.APM").is_none());
    }

    #[test]
    fn converts_semver_to_version_code() {
        assert_eq!(version_code_from_semver("0.8.15"), 815);
        assert_eq!(version_code_from_semver("v0.7.2"), 702);
        assert_eq!(version_code_from_semver("1.2.3"), 10203);
        assert_eq!(version_code_from_semver(""), 0);
    }

    #[test]
    fn decodes_proto_v1_frames_and_chunks() {
        let mut asm = FrameAssembler::default();
        assert!(asm.feed(r#"EVT:{"evt":"camera.capture","ts":170000,"data":{"name":"img.jpg"}}"#).is_empty());
        let lines = asm.feed("\r\nRSP:{\"id\":7,\"code\":0,\"msg\":\"ok\",\"data\":{\"level\":88}}\r\n");
        assert_eq!(lines.len(), 2);
        match Frame::decode(&lines[0]).unwrap() {
            Frame::Event { evt, ts, data } => {
                assert_eq!(evt, "camera.capture");
                assert_eq!(ts, 170000);
                assert_eq!(data["name"], "img.jpg");
            }
            _ => panic!("expected event"),
        }
        match Frame::decode(&lines[1]).unwrap() {
            Frame::Response { id, code, data, .. } => {
                assert_eq!(id, 7);
                assert_eq!(code, 0);
                assert_eq!(data["level"], 88);
            }
            _ => panic!("expected response"),
        }
    }

    #[test]
    fn classifies_v1_0_8_14_tts_speak_unknown_command_as_clean_unsupported() {
        let unsupported = classify_tts_speak_error(
            &SdkError::Device {
                code: 1001,
                msg: "unknown command: tts.speak".into(),
            },
            "0.8.14",
        );
        assert!(matches!(
            unsupported,
            DyjTtsError::Unsupported { code: Some(1001), ref message }
                if message.starts_with("unsupported:") && message.contains("0.8.14")
        ));

        // 非 1001 的临时错误（如 3001 设备忙或网络超时）保持为可重试错误，不误标为永久 unsupported
        let busy = classify_tts_speak_error(
            &SdkError::Device {
                code: 3001,
                msg: "audio device busy".into(),
            },
            "0.9.0",
        );
        assert!(matches!(busy, DyjTtsError::Other(_)));
    }

    #[test]
    fn realtime_amr_wb_decoder_preserves_dtx_sid_and_speech_lost_samples() {
        let speech_frame: [u8; 33] = [
            0x14, 0x50, 0x46, 0x0c, 0x15, 0x17, 0x57, 0x22, 0x71, 0x71, 0x42, 0x0a, 0x16, 0x97,
            0x72, 0xbf, 0xbc, 0x56, 0xc6, 0x4e, 0x4c, 0x46, 0xc7, 0xdf, 0xd4, 0x4f, 0x56, 0xd6,
            0x55, 0x16, 0x5b, 0xc4, 0x50,
        ];
        let mut payload = Vec::new();
        payload.extend_from_slice(&speech_frame);
        payload.extend_from_slice(&[0x4C, 1, 2, 3, 4, 5]); // mode 9 SID
        payload.push(0x74); // mode 14 SPEECH_LOST
        payload.push(0x7C); // mode 15 NO_DATA
        payload.extend_from_slice(&speech_frame);

        let mut amr = AmrWbDecoder::new();
        let samples = decode_realtime_amr_wb_payload(&mut amr, &payload);
        assert_eq!(samples.len(), 5 * 320);
        assert!(samples[320..4 * 320].iter().all(|&s| s == 0));
    }

    #[test]
    fn splits_ff11_writes_into_utf8_safe_mtu20_chunks() {
        let hello = format!(
            "CMD:{{\"id\":1,\"cmd\":\"proto.hello\",\"params\":{{\"name\":\"recording-card\",\"feature_bits\":7,\"auto_audio\":false}}}}\r\n"
        );
        let ascii_chunks = split_ble_mtu20_chunks(hello.as_bytes());
        assert_eq!(ascii_chunks.len(), 1);
        assert!(ascii_chunks[0].len() <= 180);
        assert_eq!(ascii_chunks[0], hello.as_bytes());

        let long_cn = "测试点一机蓝牙语音控制".repeat(12);
        let utf8_cmd = format!(
            "CMD:{{\"id\":2,\"cmd\":\"tts.speak\",\"params\":{{\"text\":\"{long_cn}\"}}}}\r\n"
        );
        assert!(utf8_cmd.len() > 200);
        let utf8_chunks = split_ble_mtu20_chunks(utf8_cmd.as_bytes());
        assert!(utf8_chunks.len() >= 2);
        let mut rebuilt_utf8 = String::new();
        for ch in &utf8_chunks {
            assert!(!ch.is_empty() && ch.len() <= 180);
            let s = std::str::from_utf8(ch).expect("chunk must stay on valid UTF-8 boundary");
            rebuilt_utf8.push_str(s);
        }
        assert_eq!(rebuilt_utf8, utf8_cmd);
    }

    #[test]
    fn dyj_keepalive_gate_respects_recent_io_and_cooldown() {
        assert!(!should_send_dyj_keepalive(100_000, 99_500, 0, 60_000));
        assert!(!should_send_dyj_keepalive(159_999, 100_000, 0, 60_000));
        assert!(should_send_dyj_keepalive(160_000, 100_000, 0, 60_000));
        // Even if last_io is stale (e.g. attempt failed), do not spam within interval.
        assert!(!should_send_dyj_keepalive(165_000, 100_000, 160_000, 60_000));
        assert!(should_send_dyj_keepalive(220_000, 100_000, 160_000, 60_000));
    }
}
