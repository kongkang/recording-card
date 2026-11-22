//! GATT 会话：把 D3200 的命令面收成 `RecorderDevice`。

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use btleplug::api::{CharPropFlags, Characteristic, Peripheral as _, WriteType};
use btleplug::platform::Peripheral;
use futures::StreamExt;
use reai_ext_sdk::audio::ogg_opus_to_wav_16k_mono;
use reai_ext_sdk::{
    RecorderDevice, RecorderSdkDriver, SdkAudioChunk, SdkBattery, SdkCapabilities, SdkDeviceEvent,
    SdkError, SdkFileEntry, SdkRecordStatus, SdkSavedFile, SdkSnapshot, SdkStorage,
};
use serde_json::json;
use tokio::sync::{broadcast, mpsc, oneshot};
use uuid::Uuid;

use crate::protocol::{
    self, command, file_id_from_name, payload_of, status_ok, DeviceCrypto, DeviceInfo, FileSecret,
    Packets, CMD_DELETE, CMD_HANDSHAKE, CMD_INFO, CMD_LIST, CMD_RECORD, CMD_SYNC_TIME, CMD_TRANSFER,
    NOTIFY_UUID, SERVICE_UUID, WRITE_UUID,
};

const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(8);
const TRANSFER_IDLE: Duration = Duration::from_secs(20);

pub struct FeishuSdkDriver;

fn capabilities() -> SdkCapabilities {
    SdkCapabilities {
        device_kind: "feishu_d3200",
        display_model: "飞书录音豆",
        realtime_audio: false,
        has_onboard_storage: true,
        has_file_sync: true,
        has_wifi_config: false,
        has_camera_media: false,
        has_physical_record_toggle: true,
        has_remote_record_control: true,
        has_voice_key: false,
        has_mark_button: false,
        has_configurable_buttons: false,
        ota_mode: "none",
    }
}

fn record_status(code: u8) -> SdkRecordStatus {
    SdkRecordStatus {
        is_recording: code == 1,
        realtime_enabled: false,
        session: None,
        error: None,
        reason: None,
    }
}

#[async_trait]
impl RecorderSdkDriver for FeishuSdkDriver {
    fn device_kind(&self) -> &'static str {
        "feishu_d3200"
    }

    fn display_model(&self) -> &'static str {
        "飞书录音豆"
    }

    fn default_capabilities(&self) -> SdkCapabilities {
        capabilities()
    }

    fn matches_advertisement(
        &self,
        local_name: Option<&str>,
        services: &[Uuid],
        _manufacturer_data: &std::collections::HashMap<u16, Vec<u8>>,
    ) -> bool {
        if services.iter().any(|uuid| *uuid == SERVICE_UUID) {
            return true;
        }
        let Some(name) = local_name.map(str::trim).filter(|s| !s.is_empty()) else {
            return false;
        };
        let lower = name.to_ascii_lowercase();
        lower == "soundcore work"
            || lower.starts_with("soundcore work ")
            || lower.starts_with("d3200")
            || name == "录音豆"
            || name.starts_with("飞书录音豆")
    }

    fn fallback_ble_name(&self, peripheral_id: &str) -> String {
        let compact: String = peripheral_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .rev()
            .take(4)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let suffix = if compact.is_empty() {
            "0000".to_string()
        } else {
            compact.to_ascii_uppercase()
        };
        format!("D3200-{suffix}")
    }

    async fn connect(
        &self,
        peripheral: Peripheral,
        ble_name: String,
    ) -> Result<Arc<dyn RecorderDevice>, SdkError> {
        if !peripheral
            .is_connected()
            .await
            .map_err(|err| SdkError::Ble(format!("检查录音豆连接状态失败: {err}")))?
        {
            match tokio::time::timeout(Duration::from_secs(18), peripheral.connect()).await {
                Ok(Ok(())) => {}
                Ok(Err(err)) => return Err(SdkError::Ble(format!("连接录音豆失败: {err}"))),
                Err(_) => {
                    let _ =
                        tokio::time::timeout(Duration::from_secs(2), peripheral.disconnect()).await;
                    return Err(SdkError::Timeout("飞书录音豆蓝牙建连超时".into()));
                }
            }
        }
        let opened = async {
            tokio::time::timeout(Duration::from_secs(15), peripheral.discover_services())
                .await
                .map_err(|_| SdkError::Timeout("发现录音豆 GATT 服务超时".into()))?
                .map_err(|err| SdkError::Ble(format!("发现 GATT 服务失败: {err}")))?;
            let chars = peripheral.characteristics();
            let write = chars
                .iter()
                .find(|item| item.uuid == WRITE_UUID)
                .cloned()
                .ok_or_else(|| SdkError::Protocol("录音豆没有写特征 7777".into()))?;
            let notify = chars
                .iter()
                .find(|item| item.uuid == NOTIFY_UUID)
                .cloned()
                .ok_or_else(|| SdkError::Protocol("录音豆没有通知特征 8888".into()))?;
            peripheral
                .subscribe(&notify)
                .await
                .map_err(|err| SdkError::Ble(format!("订阅录音豆通知失败: {err}")))?;
            let stream = peripheral
                .notifications()
                .await
                .map_err(|err| SdkError::Ble(format!("读取录音豆通知失败: {err}")))?;
            let write_type = if write.properties.contains(CharPropFlags::WRITE) {
                WriteType::WithResponse
            } else {
                WriteType::WithoutResponse
            };
            let (tx, rx) = mpsc::unbounded_channel();
            tokio::spawn(async move {
                let mut stream = stream;
                while let Some(note) = stream.next().await {
                    if note.uuid == NOTIFY_UUID {
                        let _ = tx.send(note.value);
                    }
                }
            });
            FeishuSession::open(BleLink::new(peripheral.clone(), write, write_type), rx, ble_name)
                .await
        }
        .await;
        match opened {
            Ok(session) => Ok(Arc::new(session)),
            Err(err) => {
                let _ = peripheral.disconnect().await;
                Err(err)
            }
        }
    }
}

#[async_trait]
trait FeishuLink: Send + Sync {
    async fn write(&self, bytes: &[u8]) -> Result<(), SdkError>;
    async fn disconnect(&self) -> Result<(), SdkError>;
}

struct BleLink {
    peripheral: Peripheral,
    write: Characteristic,
    write_type: WriteType,
}

impl BleLink {
    fn new(peripheral: Peripheral, write: Characteristic, write_type: WriteType) -> Self {
        Self {
            peripheral,
            write,
            write_type,
        }
    }
}

#[async_trait]
impl FeishuLink for BleLink {
    async fn write(&self, bytes: &[u8]) -> Result<(), SdkError> {
        self.peripheral
            .write(&self.write, bytes, self.write_type)
            .await
            .map_err(|err| SdkError::Ble(format!("写入录音豆指令失败: {err}")))
    }

    async fn disconnect(&self) -> Result<(), SdkError> {
        self.peripheral
            .disconnect()
            .await
            .map_err(|err| SdkError::Ble(format!("断开录音豆失败: {err}")))
    }
}

#[cfg(test)]
struct MemLink {
    tx: mpsc::UnboundedSender<Vec<u8>>,
}

#[cfg(test)]
#[async_trait]
impl FeishuLink for MemLink {
    async fn write(&self, bytes: &[u8]) -> Result<(), SdkError> {
        self.tx
            .send(bytes.to_vec())
            .map_err(|_| SdkError::Disconnected)
    }

    async fn disconnect(&self) -> Result<(), SdkError> {
        Ok(())
    }
}

struct FrameRouter {
    parser: Mutex<Packets>,
    pending: Mutex<BTreeMap<(u8, u8), oneshot::Sender<Vec<u8>>>>,
    transfer: Mutex<Option<mpsc::UnboundedSender<Vec<u8>>>>,
    record: Arc<AtomicU8>,
    events: broadcast::Sender<SdkDeviceEvent>,
    closed: AtomicBool,
}

impl FrameRouter {
    fn new(record: Arc<AtomicU8>, events: broadcast::Sender<SdkDeviceEvent>) -> Self {
        Self {
            parser: Mutex::new(Packets::new()),
            pending: Mutex::new(BTreeMap::new()),
            transfer: Mutex::new(None),
            record,
            events,
            closed: AtomicBool::new(false),
        }
    }

    fn register(&self, kind: u8, ident: u8) -> oneshot::Receiver<Vec<u8>> {
        let (tx, rx) = oneshot::channel();
        self.pending.lock().expect("pending").insert((kind, ident), tx);
        rx
    }

    fn cancel(&self, kind: u8, ident: u8) {
        self.pending.lock().expect("pending").remove(&(kind, ident));
    }

    fn set_transfer(&self, tx: mpsc::UnboundedSender<Vec<u8>>) {
        *self.transfer.lock().expect("transfer") = Some(tx);
    }

    fn clear_transfer(&self) {
        *self.transfer.lock().expect("transfer") = None;
    }

    fn feed(&self, chunk: &[u8]) {
        let frames = self.parser.lock().expect("parser").feed(chunk);
        for raw in frames {
            if raw.len() < 7 {
                continue;
            }
            let kind = raw[5];
            let ident = raw[6];
            if kind == CMD_RECORD.0 && ident == CMD_RECORD.1 && raw.len() > 9 && raw[9] <= 2 {
                self.record.store(raw[9], Ordering::Relaxed);
                let _ = self
                    .events
                    .send(SdkDeviceEvent::RecordStatus(record_status(raw[9])));
            }
            if let Some(tx) = self.transfer.lock().expect("transfer").as_ref() {
                if kind == 0x1A && matches!(ident, 0x07 | 0x08 | 0x12 | 0x0A) {
                    let _ = tx.send(raw.clone());
                }
            }
            if let Some(waiter) = self.pending.lock().expect("pending").remove(&(kind, ident)) {
                let _ = waiter.send(raw);
            }
        }
    }

    fn close(&self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        self.pending.lock().expect("pending").clear();
        self.clear_transfer();
        let _ = self.events.send(SdkDeviceEvent::Disconnected);
    }
}

struct FeishuSession<L: FeishuLink> {
    name: String,
    link: L,
    router: Arc<FrameRouter>,
    crypto: Mutex<DeviceCrypto>,
    info: Mutex<DeviceInfo>,
    files: Mutex<Vec<protocol::DirectoryEntry>>,
    record: Arc<AtomicU8>,
    events: broadcast::Sender<SdkDeviceEvent>,
    audio: broadcast::Sender<SdkAudioChunk>,
}

impl<L: FeishuLink + 'static> FeishuSession<L> {
    async fn open(
        link: L,
        mut notes: mpsc::UnboundedReceiver<Vec<u8>>,
        name: String,
    ) -> Result<Self, SdkError> {
        let (events, _) = broadcast::channel(32);
        let (audio, _) = broadcast::channel(8);
        let record = Arc::new(AtomicU8::new(0));
        let router = Arc::new(FrameRouter::new(record.clone(), events.clone()));
        let reader_router = router.clone();
        tokio::spawn(async move {
            while let Some(chunk) = notes.recv().await {
                reader_router.feed(&chunk);
            }
            reader_router.close();
        });
        let session = Self {
            name,
            link,
            router,
            crypto: Mutex::new(DeviceCrypto::generate()),
            info: Mutex::new(DeviceInfo {
                battery: 0,
                charging: false,
                firmware: String::new(),
                serial: String::new(),
                total_kb: 0,
                free_kb: 0,
                record_status: 0,
            }),
            files: Mutex::new(Vec::new()),
            record,
            events,
            audio,
        };
        let frame = session.exchange(CMD_INFO.0, CMD_INFO.1, &[]).await?;
        let info = protocol::parse_info(payload_of(&frame)?)?;
        session.record.store(info.record_status, Ordering::Relaxed);
        *session.info.lock().expect("info") = info;
        Ok(session)
    }

    async fn exchange(&self, kind: u8, ident: u8, payload: &[u8]) -> Result<Vec<u8>, SdkError> {
        if self.router.closed.load(Ordering::SeqCst) {
            return Err(SdkError::Disconnected);
        }
        let rx = self.router.register(kind, ident);
        if let Err(err) = self.link.write(&command(kind, ident, payload)).await {
            self.router.cancel(kind, ident);
            return Err(err);
        }
        match tokio::time::timeout(EXCHANGE_TIMEOUT, rx).await {
            Ok(Ok(frame)) => Ok(frame),
            Ok(Err(_)) => Err(SdkError::Disconnected),
            Err(_) => {
                self.router.cancel(kind, ident);
                Err(SdkError::Timeout("录音豆回应超时".into()))
            }
        }
    }

    async fn ensure_session_key(&self) -> Result<(), SdkError> {
        if self.crypto.lock().expect("crypto").session_key.is_some() {
            return Ok(());
        }
        let public_key = self.crypto.lock().expect("crypto").public_key();
        let frame = self
            .exchange(CMD_HANDSHAKE.0, CMD_HANDSHAKE.1, &public_key)
            .await?;
        self.crypto
            .lock()
            .expect("crypto")
            .accept_peer(payload_of(&frame)?)
    }

    fn remember_files(&self, rows: Vec<protocol::DirectoryEntry>) {
        *self.files.lock().expect("files") = rows;
    }

    fn entry_by_name(&self, name: &str) -> Result<protocol::DirectoryEntry, SdkError> {
        let id = file_id_from_name(name)?;
        self.files
            .lock()
            .expect("files")
            .iter()
            .find(|row| row.id == id)
            .cloned()
            .ok_or_else(|| SdkError::Protocol("设备目录中没有此录音，请刷新".into()))
    }

    fn snapshot_from_cache(&self) -> SdkSnapshot {
        let info = self.info.lock().expect("info").clone();
        let total_mb = u64::from(info.total_kb) / 1024;
        let free_mb = u64::from(info.free_kb.min(info.total_kb)) / 1024;
        let used_mb = total_mb.saturating_sub(free_mb);
        SdkSnapshot {
            capabilities: capabilities(),
            device_name: self.name.clone(),
            device_id: info.serial.clone(),
            fw_version: info.firmware.clone(),
            battery: SdkBattery {
                level: Some(info.battery),
                is_charging: info.charging,
            },
            storage: Some(SdkStorage {
                total_mb,
                used_mb,
                free_mb,
            }),
            record: record_status(self.record.load(Ordering::Relaxed)),
        }
    }
}

#[async_trait]
impl<L: FeishuLink + 'static> RecorderDevice for FeishuSession<L> {
    fn device_name(&self) -> &str {
        &self.name
    }

    fn capabilities(&self) -> SdkCapabilities {
        capabilities()
    }

    fn subscribe_events(&self) -> broadcast::Receiver<SdkDeviceEvent> {
        self.events.subscribe()
    }

    fn subscribe_audio(&self) -> broadcast::Receiver<SdkAudioChunk> {
        self.audio.subscribe()
    }

    async fn snapshot(&self) -> Result<SdkSnapshot, SdkError> {
        match self.exchange(CMD_INFO.0, CMD_INFO.1, &[]).await {
            Ok(frame) => {
                if let Ok(info) = protocol::parse_info(payload_of(&frame)?) {
                    self.record.store(info.record_status, Ordering::Relaxed);
                    *self.info.lock().expect("info") = info;
                }
            }
            Err(SdkError::Disconnected) => return Err(SdkError::Disconnected),
            Err(_) => {}
        }
        Ok(self.snapshot_from_cache())
    }

    async fn sync_time(&self) -> Result<serde_json::Value, SdkError> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as u32)
            .unwrap_or(0);
        let mut payload = now.to_le_bytes().to_vec();
        payload.push(0);
        let frame = self
            .exchange(CMD_SYNC_TIME.0, CMD_SYNC_TIME.1, &payload)
            .await?;
        if !status_ok(&frame) {
            return Err(SdkError::Protocol("录音豆拒绝时间同步".into()));
        }
        Ok(json!({ "synced": true, "epoch": now }))
    }

    async fn start_record(&self, _duration_secs: Option<u32>) -> Result<SdkRecordStatus, SdkError> {
        self.set_record(1).await
    }

    async fn stop_record(&self) -> Result<SdkRecordStatus, SdkError> {
        self.set_record(2).await
    }

    async fn set_realtime_enabled(&self, enabled: bool) -> Result<(), SdkError> {
        if enabled {
            Err(SdkError::Unsupported(
                "飞书录音豆当前接入包只同步板载录音，不开启实时流".into(),
            ))
        } else {
            Ok(())
        }
    }

    async fn list_files(&self) -> Result<Vec<SdkFileEntry>, SdkError> {
        let mut collected = BTreeMap::<u32, protocol::DirectoryEntry>::new();
        for page in 0..50u16 {
            let frame = self
                .exchange(CMD_LIST.0, CMD_LIST.1, &page.to_le_bytes())
                .await?;
            let (rows, count) = protocol::parse_directory(payload_of(&frame)?)?;
            for row in rows {
                if row.duration_ms > 0 {
                    collected.insert(row.id, row);
                }
            }
            if count < 10 {
                let rows: Vec<_> = collected.into_values().rev().collect();
                let entries = rows.iter().map(file_entry).collect();
                self.remember_files(rows);
                return Ok(entries);
            }
        }
        Err(SdkError::Protocol("设备录音目录尚未读取完".into()))
    }

    async fn download_file(&self, name: &str, dir: &str) -> Result<SdkSavedFile, SdkError> {
        if self.entry_by_name(name).is_err() {
            self.list_files().await?;
        }
        let entry = self.entry_by_name(name)?;
        self.ensure_session_key().await?;
        let (tx, mut rx) = mpsc::unbounded_channel();
        self.router.set_transfer(tx);
        let _transfer_guard = TransferGuard(&self.router);
        let mut request = Vec::with_capacity(9);
        request.extend_from_slice(&0u32.to_le_bytes());
        request.extend_from_slice(&entry.id.to_le_bytes());
        request.push(0);
        let write = self
            .link
            .write(&command(CMD_TRANSFER.0, CMD_TRANSFER.1, &request))
            .await;
        if let Err(err) = write {
            self.router.clear_transfer();
            return Err(err);
        }

        let mut secret: Option<FileSecret> = None;
        let mut frames: BTreeMap<u32, Vec<u8>> = BTreeMap::new();
        let result = 'read: loop {
            let raw = match tokio::time::timeout(TRANSFER_IDLE, rx.recv()).await {
                Ok(Some(raw)) => raw,
                Ok(None) => break Err(SdkError::Disconnected),
                Err(_) => {
                    break Err(SdkError::Timeout(
                        "文件读取超时：持续未收到新的音频数据".into(),
                    ))
                }
            };
            if raw.len() < 7 {
                continue;
            }
            match raw[6] {
                0x07 => {
                    let opened = {
                        let crypto = self.crypto.lock().expect("crypto");
                        match payload_of(&raw).and_then(|body| crypto.open_file_key(body, entry.id)) {
                            Ok(opened) => opened,
                            Err(err) => break 'read Err(err),
                        }
                    };
                    secret = Some(opened);
                }
                0x08 | 0x12 => {
                    let Some(secret) = secret.as_ref() else {
                        break 'read Err(SdkError::Protocol(
                            "收到音频分片但缺少已验证文件头".into(),
                        ));
                    };
                    let units = match payload_of(&raw).and_then(protocol::slice_units) {
                        Ok(units) => units,
                        Err(err) => break 'read Err(err),
                    };
                    for (seq, cipher) in units {
                        let plain = match secret.decrypt_frame(seq, &cipher) {
                            Ok(plain) => plain,
                            Err(err) => break 'read Err(err),
                        };
                        if let Some(previous) = frames.get(&seq) {
                            if previous != &plain {
                                break 'read Err(SdkError::Protocol("音频分片内容冲突".into()));
                            }
                            continue;
                        }
                        frames.insert(seq, plain);
                    }
                }
                0x0A => break Ok(()),
                _ => {}
            }
        };
        drop(_transfer_guard);
        result?;
        let ordered = finish_frames(&frames, entry.duration_ms)?;
        let ogg = protocol::mux_ogg(&ordered)?;
        let directory = PathBuf::from(dir);
        std::fs::create_dir_all(&directory)?;
        let ogg_path = directory.join(format!("{}.ogg", entry.id));
        let wav_path = directory.join(format!("{}.wav", entry.id));
        std::fs::write(&ogg_path, &ogg)?;
        let transcoded = ogg_opus_to_wav_16k_mono(&ogg_path, &wav_path);
        let _ = std::fs::remove_file(&ogg_path);
        transcoded?;
        let bytes_written = std::fs::metadata(&wav_path).map(|meta| meta.len()).unwrap_or(0);
        let ts_sec = (entry.id >= 1_577_836_800 && entry.id < 4_102_444_800).then_some(i64::from(entry.id));
        Ok(SdkSavedFile {
            path: wav_path,
            bytes_written,
            original_name: file_entry(&entry).name,
            device_name: Some(self.name.clone()),
            start_at: ts_sec,
            time_synced: Some(ts_sec.is_some()),
            parts: Vec::new(),
        })
    }

    async fn delete_file(&self, name: &str) -> Result<(), SdkError> {
        let id = file_id_from_name(name)?;
        let frame = self
            .exchange(CMD_DELETE.0, CMD_DELETE.1, &id.to_le_bytes())
            .await?;
        if !status_ok(&frame) {
            return Err(SdkError::Protocol("录音豆拒绝删除该录音".into()));
        }
        self.files
            .lock()
            .expect("files")
            .retain(|row| row.id != id);
        Ok(())
    }

    async fn disconnect(&self) -> Result<(), SdkError> {
        self.router.close();
        self.link.disconnect().await
    }
}

impl<L: FeishuLink + 'static> FeishuSession<L> {
    async fn set_record(&self, target: u8) -> Result<SdkRecordStatus, SdkError> {
        let frame = self
            .exchange(CMD_RECORD.0, CMD_RECORD.1, &[target])
            .await?;
        let echoed = payload_of(&frame)?.first().copied();
        if echoed != Some(target) {
            return Err(SdkError::Protocol("未收到预期录音状态".into()));
        }
        self.record.store(target, Ordering::Relaxed);
        let status = record_status(target);
        let _ = self.events.send(SdkDeviceEvent::RecordStatus(status.clone()));
        Ok(status)
    }
}

struct TransferGuard<'a>(&'a FrameRouter);

impl Drop for TransferGuard<'_> {
    fn drop(&mut self) {
        self.0.clear_transfer();
    }
}

fn file_entry(row: &protocol::DirectoryEntry) -> SdkFileEntry {
    let ts_sec =
        (row.id >= 1_577_836_800 && row.id < 4_102_444_800).then_some(i64::from(row.id));
    SdkFileEntry {
        name: format!("{}.opus", row.id),
        size: u64::from(row.duration_ms).saturating_mul(8),
        index: None,
        created_at: ts_sec,
        session: None,
        seq: None,
        start_at: ts_sec,
        synced: Some(ts_sec.is_some()),
    }
}

fn finish_frames(
    frames: &BTreeMap<u32, Vec<u8>>,
    duration_ms: u32,
) -> Result<Vec<Vec<u8>>, SdkError> {
    if frames.is_empty() {
        return Err(SdkError::Protocol("设备没有返回完整可解密音频".into()));
    }
    let first = *frames.keys().next().unwrap();
    let last = *frames.keys().next_back().unwrap();
    let expected_len = last as usize - first as usize + 1;
    if first > 1 || frames.len() != expected_len {
        return Err(SdkError::Protocol("音频分片缺失，未写入资料库".into()));
    }
    let expected_frames = duration_ms / 20;
    if expected_frames > 0 && frames.len() as u32 != expected_frames {
        return Err(SdkError::Protocol("音频帧数与目录时长不一致，未写入资料库".into()));
    }
    Ok(frames.values().cloned().collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{response, seal_file_head, seal_frame, DeviceCrypto};

    const OPUS_20MS: &[u8] = &[0x48, 0x0b, 0xe4, 0xc1, 0x36, 0xec, 0xc5, 0x80];

    #[tokio::test]
    async fn scripted_bean_lists_and_downloads_a_wav() {
        let (write_tx, mut write_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (note_tx, note_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        tokio::spawn(async move {
            let device = DeviceCrypto::generate();
            let mut session_key = None::<[u8; 32]>;
            let file_key = [4u8; 32];
            let nonce = [5u8; 12];
            while let Some(frame) = write_rx.recv().await {
                if frame.len() < 10 {
                    continue;
                }
                let kind = frame[5];
                let ident = frame[6];
                let payload = &frame[9..frame.len() - 1];
                let reply = match (kind, ident) {
                    (0x01, 0x01) => Some(response(0x01, 0x01, 1, &sample_info())),
                    (0x01, 0xA6) => Some(response(0x01, 0xA6, 1, &[])),
                    (0x2E, 0x01) => {
                        let (body, key) = device.answer_peer(payload).unwrap();
                        session_key = Some(key);
                        Some(response(0x2E, 0x01, 1, &body))
                    }
                    (0x1B, 0x0E) => Some(response(0x1B, 0x0E, 1, &sample_directory())),
                    (0x1A, 0x07) => {
                        let key = session_key.unwrap();
                        let session_nonce = [8u8; 16];
                        let frame_count = 8u32;
                        let head = seal_file_head(
                            &key,
                            1_700_000_000,
                            frame_count,
                            &file_key,
                            &nonce,
                            &session_nonce,
                        )
                        .unwrap();
                        let _ = note_tx.send(response(0x1A, 0x07, 1, &head));
                        let secret = FileSecret {
                            file_key,
                            nonce,
                            size: frame_count.saturating_mul(166),
                        };
                        let mut slices = Vec::new();
                        for seq in 0..frame_count {
                            slices.extend_from_slice(&seal_frame(&secret, seq, OPUS_20MS).unwrap());
                        }
                        let _ = note_tx.send(response(0x1A, 0x08, 1, &slices));
                        Some(response(0x1A, 0x0A, 1, &[]))
                    }
                    (0x1A, 0x10) => Some(response(0x1A, 0x10, 1, &[])),
                    (0x18, 0x82) => Some(response(0x18, 0x82, 1, payload)),
                    _ => None,
                };
                if let Some(reply) = reply {
                    let _ = note_tx.send(reply);
                }
            }
        });

        let session = FeishuSession::open(MemLink { tx: write_tx }, note_rx, "D3200-TEST".into())
            .await
            .unwrap();
        let snap = session.snapshot().await.unwrap();
        assert_eq!(snap.device_id, "007f1d04cca3");
        assert_eq!(snap.fw_version, "04.92");
        assert!(snap.capabilities.has_file_sync);
        assert!(snap.capabilities.has_remote_record_control);
        assert!(!snap.capabilities.realtime_audio);
        assert!(!snap.capabilities.has_wifi_config);

        let files = session.list_files().await.unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].name, "1700000000.opus");
        assert_eq!(files[0].start_at, Some(1_700_000_000));
        assert_eq!(files[0].synced, Some(true));

        let dir = std::env::temp_dir().join(format!("feishu-sdk-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let saved = session
            .download_file(&files[0].name, dir.to_str().unwrap())
            .await
            .unwrap();
        assert!(saved.path.ends_with("1700000000.wav"));
        assert_eq!(saved.start_at, Some(1_700_000_000));
        assert_eq!(saved.time_synced, Some(true));
        assert!(saved.bytes_written > 44);
        let wav = std::fs::read(&saved.path).unwrap();
        assert_eq!(&wav[..4], b"RIFF");
        let started = session.start_record(None).await.unwrap();
        assert!(started.is_recording);
        let stopped = session.stop_record().await.unwrap();
        assert!(!stopped.is_recording);
        session.delete_file(&files[0].name).await.unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn sample_info() -> Vec<u8> {
        let mut payload = vec![0u8; 51];
        payload[1] = 7;
        payload[2] = 1;
        payload[3..8].copy_from_slice(b"04.92");
        payload[8..20].copy_from_slice(b"007F1D04CCA3");
        payload[24..28].copy_from_slice(&(8 * 1024 * 1024u32).to_le_bytes());
        payload[28..32].copy_from_slice(&(6 * 1024 * 1024u32).to_le_bytes());
        payload
    }

    fn sample_directory() -> Vec<u8> {
        let mut payload = vec![1, 0];
        payload.extend_from_slice(&1_700_000_000u32.to_le_bytes());
        payload.extend_from_slice(&1_700_000_160u32.to_le_bytes());
        payload.extend_from_slice(&160u32.to_le_bytes());
        payload.extend_from_slice(&[0u8; 8]);
        payload
    }
}
