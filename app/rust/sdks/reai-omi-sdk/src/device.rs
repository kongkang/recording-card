use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use btleplug::api::{Characteristic, Peripheral as _, WriteType};
use btleplug::platform::Peripheral;
use futures::StreamExt;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, Mutex};
use tokio::task::JoinHandle;
use uuid::Uuid;

use reai_ext_sdk::audio::write_wav_16k_mono;
use reai_ext_sdk::{
    RecorderDevice, RecorderSdkDriver, SdkAudioChunk, SdkBattery, SdkCapabilities, SdkDeviceEvent,
    SdkError, SdkFileEntry, SdkRecordStatus, SdkSavedFile, SdkSavedFilePart, SdkSnapshot,
};

use crate::protocol::{
    decode_button_gesture, extract_len_prefixed_frames, is_plausible_unix_sec, matches_omi_name,
    parse_multi_file_list, parse_ring_info, split_friend_pendant_lc3_frames,
    split_ring_encoded_segments, MultiFileEntry, OmiAudioCodec, OmiFrameDecoder,
    OmiPacketReassembler, RingBufferInfo, RingTimedSegment, CHR_BATTERY_LEVEL_UUID,
    CHR_FRIEND_PENDANT_AUDIO_UUID, CHR_FW_REV_UUID, CHR_MODEL_NUMBER_UUID,
    CHR_OMI_AUDIO_CODEC_UUID, CHR_OMI_AUDIO_DATA_UUID, CHR_OMI_BUTTON_TRIGGER_UUID,
    CHR_OMI_CHARGING_UUID, CHR_OMI_MUTE_UUID, CHR_OMI_STORAGE_CTRL_UUID, CHR_OMI_STORAGE_DATA_UUID,
    CHR_OMI_TIMESYNC_WRITE_UUID, RING_CMD_ADVANCE, RING_CMD_INFO, RING_CMD_READ, RING_CMD_STOP,
    RING_NOTIFY_ACK, RING_NOTIFY_DATA, RING_NOTIFY_DONE, SVC_BATTERY_UUID, SVC_DIS_UUID,
    SVC_FRIEND_PENDANT_UUID, SVC_OMI_AUDIO_UUID, SVC_OMI_BUTTON_UUID, SVC_OMI_STORAGE_UUID,
};

pub const RING_RECORDS_PER_CHUNK: u32 = 1_800;
const BLE_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const BLE_DISCOVER_TIMEOUT: Duration = Duration::from_secs(10);
const BLE_GATT_TIMEOUT: Duration = Duration::from_secs(3);

/// 将 `[read_seq, write_seq)` 拆分为有界分块，单块上限 `chunk_records`（默认 1,800 条 ≈ 5 分钟）。
/// 避免 Omi 离线积压数小时录音时一次 `RING_CMD_READ` 超时或 OOM，同时让 `delete_file` 逐块安全推进 `read_seq`。
pub fn plan_ring_chunks(read_seq: u64, write_seq: u64, chunk_records: u32) -> Vec<(u64, u64)> {
    if write_seq <= read_seq {
        return Vec::new();
    }
    let step = u64::from(chunk_records.max(1));
    let mut chunks = Vec::new();
    let mut cursor = read_seq;
    while cursor < write_seq {
        let end = cursor.saturating_add(step).min(write_seq);
        chunks.push((cursor, end));
        cursor = end;
    }
    chunks
}

/// 从 `OMI_RING_{start}_{end}.wav` 解析分块序列范围，供 `download_file`/`delete_file` 在重建列表前兜底使用。
pub fn parse_ring_chunk_filename(name: &str) -> Option<(u64, u64)> {
    let stripped = name.strip_prefix("OMI_RING_")?;
    let stem = stripped
        .strip_suffix(".wav")
        .or_else(|| stripped.strip_suffix(".WAV"))?;
    let (s, e) = stem.split_once('_')?;
    let start = s.parse::<u64>().ok()?;
    let end = e.parse::<u64>().ok()?;
    (end > start).then_some((start, end))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OmiHardwareVariant {
    Cv1,
    FriendPendant,
}

#[derive(Debug, Clone)]
enum OmiStorageHandle {
    Ring { read_seq: u64, write_seq: u64 },
    MultiFile(MultiFileEntry),
    Legacy { offset: u32, total_bytes: u32 },
}

pub struct OmiSdkDriver;

impl OmiSdkDriver {
    pub fn capabilities(has_storage: bool, has_button: bool) -> SdkCapabilities {
        SdkCapabilities {
            device_kind: "omi_cv1",
            display_model: "Omi 录音器",
            realtime_audio: true,
            has_onboard_storage: has_storage,
            has_file_sync: has_storage,
            has_wifi_config: false,
            has_camera_media: false,
            has_physical_record_toggle: true,
            has_remote_record_control: true,
            // Omi 固件写死长按约 3 秒直接硬件关机且不可通过 BLE 更改，禁用长按语音键以防误触关机
            has_voice_key: false,
            has_mark_button: has_button,
            has_configurable_buttons: has_button,
            ota_mode: "none",
        }
    }
}

#[async_trait]
impl RecorderSdkDriver for OmiSdkDriver {
    fn device_kind(&self) -> &'static str {
        "omi_cv1"
    }

    fn display_model(&self) -> &'static str {
        "Omi 录音器"
    }

    fn default_capabilities(&self) -> SdkCapabilities {
        Self::capabilities(true, true)
    }

    fn matches_advertisement(
        &self,
        local_name: Option<&str>,
        services: &[Uuid],
        _manufacturer_data: &HashMap<u16, Vec<u8>>,
    ) -> bool {
        if services
            .iter()
            .any(|s| *s == SVC_OMI_AUDIO_UUID || *s == SVC_FRIEND_PENDANT_UUID)
        {
            return true;
        }
        local_name.is_some_and(|n| matches_omi_name(n.trim()))
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
            "CV1".to_string()
        } else {
            compact.to_ascii_uppercase()
        };
        format!("Omi-{suffix}")
    }

    async fn connect(
        &self,
        peripheral: Peripheral,
        ble_name: String,
    ) -> Result<Arc<dyn RecorderDevice>, SdkError> {
        let dev = OmiDevice::connect_peripheral(peripheral, ble_name).await?;
        Ok(dev)
    }
}

pub struct OmiDevice {
    peripheral: Peripheral,
    name: String,
    peripheral_id: String,
    variant: OmiHardwareVariant,
    caps: SdkCapabilities,
    audio_data_char: Characteristic,
    audio_codec_char: Option<Characteristic>,
    battery_char: Option<Characteristic>,
    charging_char: Option<Characteristic>,
    mute_char: Option<Characteristic>,
    button_char: Option<Characteristic>,
    timesync_char: Option<Characteristic>,
    storage_data_char: Option<Characteristic>,
    storage_ctrl_char: Option<Characteristic>,
    fw_version: String,
    model_number: String,
    codec: Mutex<OmiAudioCodec>,
    battery_cache: Mutex<SdkBattery>,
    recording: AtomicBool,
    realtime_enabled: AtomicBool,
    session_seq: AtomicU64,
    active_session: Mutex<Option<String>>,
    storage_lock: Mutex<()>,
    storage_rx: Mutex<mpsc::UnboundedReceiver<Vec<u8>>>,
    storage_index: Mutex<HashMap<String, OmiStorageHandle>>,
    events_tx: broadcast::Sender<SdkDeviceEvent>,
    audio_tx: broadcast::Sender<SdkAudioChunk>,
    connected: AtomicBool,
    pump_task: Mutex<Option<JoinHandle<()>>>,
}

impl OmiDevice {
    async fn connect_peripheral(
        peripheral: Peripheral,
        ble_name: String,
    ) -> Result<Arc<Self>, SdkError> {
        let already_connected = tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.is_connected())
            .await
            .map_err(|_| SdkError::Timeout("检查 Omi 连接状态超时".into()))?
            .map_err(|e| SdkError::Ble(e.to_string()))?;
        if !already_connected {
            tokio::time::timeout(BLE_CONNECT_TIMEOUT, peripheral.connect())
                .await
                .map_err(|_| SdkError::Timeout("Omi 蓝牙建连超时".into()))?
                .map_err(|e| SdkError::Ble(format!("Omi 蓝牙建连失败: {e}")))?;
        }

        let setup_res = async {
            tokio::time::timeout(BLE_DISCOVER_TIMEOUT, peripheral.discover_services())
                .await
                .map_err(|_| SdkError::Timeout("发现 Omi GATT 服务超时".into()))?
                .map_err(|e| SdkError::Ble(format!("发现 Omi GATT 服务失败: {e}")))?;

            let chars = peripheral.characteristics();
            let (variant, audio_data_char) = if let Some(c) = chars
                .iter()
                .find(|c| c.uuid == CHR_OMI_AUDIO_DATA_UUID)
                .cloned()
            {
                (OmiHardwareVariant::Cv1, c)
            } else if let Some(c) = chars
                .iter()
                .find(|c| c.uuid == CHR_FRIEND_PENDANT_AUDIO_UUID)
                .cloned()
            {
                (OmiHardwareVariant::FriendPendant, c)
            } else {
                return Err(SdkError::Protocol(
                    "未在 Omi 设备上发现标准音频流服务特征".into(),
                ));
            };

            let audio_codec_char = chars
                .iter()
                .find(|c| c.uuid == CHR_OMI_AUDIO_CODEC_UUID)
                .cloned();
            let battery_char = chars
                .iter()
                .find(|c| c.uuid == CHR_BATTERY_LEVEL_UUID && c.service_uuid == SVC_BATTERY_UUID)
                .or_else(|| chars.iter().find(|c| c.uuid == CHR_BATTERY_LEVEL_UUID))
                .cloned();
            let charging_char = chars
                .iter()
                .find(|c| c.uuid == CHR_OMI_CHARGING_UUID)
                .cloned();
            let mute_char = chars.iter().find(|c| c.uuid == CHR_OMI_MUTE_UUID).cloned();
            let button_char = chars
                .iter()
                .find(|c| c.uuid == CHR_OMI_BUTTON_TRIGGER_UUID && c.service_uuid == SVC_OMI_BUTTON_UUID)
                .or_else(|| chars.iter().find(|c| c.uuid == CHR_OMI_BUTTON_TRIGGER_UUID))
                .cloned();
            let timesync_char = chars
                .iter()
                .find(|c| c.uuid == CHR_OMI_TIMESYNC_WRITE_UUID)
                .cloned();
            let storage_data_char = chars
                .iter()
                .find(|c| c.uuid == CHR_OMI_STORAGE_DATA_UUID && c.service_uuid == SVC_OMI_STORAGE_UUID)
                .or_else(|| chars.iter().find(|c| c.uuid == CHR_OMI_STORAGE_DATA_UUID))
                .cloned();
            let storage_ctrl_char = chars
                .iter()
                .find(|c| c.uuid == CHR_OMI_STORAGE_CTRL_UUID)
                .cloned();

            let fw_version = read_optional_utf8(
                &peripheral,
                chars
                    .iter()
                    .find(|c| c.uuid == CHR_FW_REV_UUID && c.service_uuid == SVC_DIS_UUID)
                    .or_else(|| chars.iter().find(|c| c.uuid == CHR_FW_REV_UUID)),
            )
            .await;
            let model_number = read_optional_utf8(
                &peripheral,
                chars
                    .iter()
                    .find(|c| c.uuid == CHR_MODEL_NUMBER_UUID && c.service_uuid == SVC_DIS_UUID)
                    .or_else(|| chars.iter().find(|c| c.uuid == CHR_MODEL_NUMBER_UUID)),
            )
            .await;

            let codec = match variant {
                OmiHardwareVariant::FriendPendant => OmiAudioCodec::Lc3Fs1030,
                OmiHardwareVariant::Cv1 => match &audio_codec_char {
                    Some(c) => match tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.read(c)).await {
                        Ok(Ok(bytes)) if !bytes.is_empty() => OmiAudioCodec::from_codec_id(bytes[0]),
                        _ => OmiAudioCodec::Opus,
                    },
                    None => OmiAudioCodec::Opus,
                },
            };

            let mut initial_battery = SdkBattery::default();
            if let Some(ref c) = battery_char {
                if let Ok(Ok(bytes)) =
                    tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.read(c)).await
                {
                    if let Some(&lvl) = bytes.first() {
                        initial_battery.level = Some(lvl.min(100));
                    }
                }
                let _ = tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.subscribe(c)).await;
            }
            if let Some(ref c) = charging_char {
                if let Ok(Ok(bytes)) =
                    tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.read(c)).await
                {
                    if let Some(&ch) = bytes.first() {
                        initial_battery.is_charging = ch != 0;
                    }
                }
                let _ = tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.subscribe(c)).await;
            }
            if let Some(ref c) = button_char {
                let _ = tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.subscribe(c)).await;
            }
            if let Some(ref c) = storage_data_char {
                let _ = tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.subscribe(c)).await;
            }

            let has_storage = storage_data_char.is_some();
            let has_button = button_char.is_some();
            let caps = OmiSdkDriver::capabilities(has_storage, has_button);

            let notif_stream = tokio::time::timeout(BLE_GATT_TIMEOUT, peripheral.notifications())
                .await
                .map_err(|_| SdkError::Timeout("获取 Omi BLE 通知流超时".into()))?
                .map_err(|e| SdkError::Ble(format!("订阅 Omi BLE 通知失败: {e}")))?;

            Ok((
                variant,
                audio_data_char,
                audio_codec_char,
                battery_char,
                charging_char,
                mute_char,
                button_char,
                timesync_char,
                storage_data_char,
                storage_ctrl_char,
                fw_version,
                model_number,
                codec,
                initial_battery,
                caps,
                notif_stream,
            ))
        }
        .await;

        let (
            variant,
            audio_data_char,
            audio_codec_char,
            battery_char,
            charging_char,
            mute_char,
            button_char,
            timesync_char,
            storage_data_char,
            storage_ctrl_char,
            fw_version,
            model_number,
            codec,
            initial_battery,
            caps,
            notif_stream,
        ) = match setup_res {
            Ok(parts) => parts,
            Err(err) => {
                // 避免连接已成功但后续服务发现/订阅失败时把物理链路留在 CoreBluetooth，导致设备常亮蓝灯且不再广播
                let _ = tokio::time::timeout(Duration::from_secs(2), peripheral.disconnect()).await;
                return Err(err);
            }
        };

        let (events_tx, _) = broadcast::channel(64);
        let (audio_tx, _) = broadcast::channel(128);
        let (storage_tx, storage_rx) = mpsc::unbounded_channel();

        let device = Arc::new(Self {
            peripheral_id: peripheral.id().to_string(),
            peripheral,
            name: ble_name,
            variant,
            caps,
            audio_data_char,
            audio_codec_char,
            battery_char,
            charging_char,
            mute_char,
            button_char,
            timesync_char,
            storage_data_char,
            storage_ctrl_char,
            fw_version,
            model_number,
            codec: Mutex::new(codec),
            battery_cache: Mutex::new(initial_battery),
            recording: AtomicBool::new(false),
            realtime_enabled: AtomicBool::new(false),
            session_seq: AtomicU64::new(0),
            active_session: Mutex::new(None),
            storage_lock: Mutex::new(()),
            storage_rx: Mutex::new(storage_rx),
            storage_index: Mutex::new(HashMap::new()),
            events_tx,
            audio_tx,
            connected: AtomicBool::new(true),
            pump_task: Mutex::new(None),
        });

        let weak = Arc::downgrade(&device);
        let task = tokio::spawn(async move {
            let mut stream = notif_stream;
            let mut reassembler = OmiPacketReassembler::default();
            let mut decoder = OmiFrameDecoder::for_codec(codec)
                .unwrap_or_else(|_| OmiFrameDecoder::Pcm16);
            let (mut audio_notifs, mut frames_ok, mut decode_err, mut gated) =
                (0u64, 0u64, 0u64, 0u64);

            while let Some(notif) = stream.next().await {
                let Some(dev) = weak.upgrade() else {
                    break;
                };
                if notif.uuid == CHR_OMI_AUDIO_DATA_UUID {
                    audio_notifs += 1;
                    if audio_notifs == 1 || audio_notifs % 100 == 0 {
                        log::info!(
                            "omi audio: notif#{audio_notifs} len={} ok={frames_ok} err={decode_err} gated={gated}",
                            notif.value.len()
                        );
                    }
                    if !dev.realtime_enabled.load(Ordering::SeqCst) {
                        gated += 1;
                        continue;
                    }
                    if let Some(frame) = reassembler.push_packet(&notif.value) {
                        match decoder.decode_frame(&frame.data) {
                            Ok(samples) if !samples.is_empty() => {
                                frames_ok += 1;
                                let _ = dev.audio_tx.send(SdkAudioChunk {
                                    samples,
                                    sample_rate: 16_000,
                                    channels: 1,
                                    discontinuous: frame.discontinuous,
                                });
                            }
                            Ok(_) => {}
                            Err(e) => {
                                decode_err += 1;
                                if decode_err <= 3 {
                                    log::info!(
                                        "omi audio: decode err#{decode_err}: {e} frame_len={}",
                                        frame.data.len()
                                    );
                                }
                            }
                        }
                    }
                } else if notif.uuid == CHR_FRIEND_PENDANT_AUDIO_UUID {
                    if !dev.realtime_enabled.load(Ordering::SeqCst) {
                        continue;
                    }
                    for lc3_frame in split_friend_pendant_lc3_frames(&notif.value) {
                        if let Ok(samples) = decoder.decode_frame(lc3_frame) {
                            if !samples.is_empty() {
                                let _ = dev.audio_tx.send(SdkAudioChunk {
                                    samples,
                                    sample_rate: 16_000,
                                    channels: 1,
                                    discontinuous: false,
                                });
                            }
                        }
                    }
                } else if notif.uuid == CHR_OMI_STORAGE_DATA_UUID {
                    let _ = storage_tx.send(notif.value);
                } else if notif.uuid == CHR_BATTERY_LEVEL_UUID {
                    if let Some(&lvl) = notif.value.first() {
                        let updated = {
                            let mut guard = dev.battery_cache.lock().await;
                            guard.level = Some(lvl.min(100));
                            guard.clone()
                        };
                        let _ = dev.events_tx.send(SdkDeviceEvent::Power(updated));
                    }
                } else if notif.uuid == CHR_OMI_CHARGING_UUID {
                    if let Some(&ch) = notif.value.first() {
                        let updated = {
                            let mut guard = dev.battery_cache.lock().await;
                            guard.is_charging = ch != 0;
                            guard.clone()
                        };
                        let _ = dev.events_tx.send(SdkDeviceEvent::Power(updated));
                    }
                } else if notif.uuid == CHR_OMI_BUTTON_TRIGGER_UUID {
                    if let Some(gesture) = decode_button_gesture(&notif.value) {
                        if gesture == "single_tap" || gesture == "double_tap" {
                            let _ = dev.events_tx.send(SdkDeviceEvent::Button {
                                gesture: gesture.to_string(),
                            });
                        }
                    }
                }
            }

            if let Some(dev) = weak.upgrade() {
                dev.connected.store(false, Ordering::SeqCst);
                let _ = dev.events_tx.send(SdkDeviceEvent::Disconnected);
            }
        });
        *device.pump_task.lock().await = Some(task);

        let _ = device.sync_time().await;
        Ok(device)
    }

    async fn read_battery_now(&self) -> SdkBattery {
        let mut guard = self.battery_cache.lock().await;
        if let Some(ref c) = self.battery_char {
            if let Ok(Ok(bytes)) =
                tokio::time::timeout(Duration::from_secs(2), self.peripheral.read(c)).await
            {
                if let Some(&lvl) = bytes.first() {
                    guard.level = Some(lvl.min(100));
                }
            }
        }
        if let Some(ref c) = self.charging_char {
            if let Ok(Ok(bytes)) =
                tokio::time::timeout(Duration::from_secs(2), self.peripheral.read(c)).await
            {
                if let Some(&ch) = bytes.first() {
                    guard.is_charging = ch != 0;
                }
            }
        }
        guard.clone()
    }

    async fn write_char_auto(
        &self,
        ch: &Characteristic,
        data: &[u8],
    ) -> Result<(), SdkError> {
        let write_type = if ch
            .properties
            .contains(btleplug::api::CharPropFlags::WRITE)
        {
            WriteType::WithResponse
        } else {
            WriteType::WithoutResponse
        };
        tokio::time::timeout(BLE_GATT_TIMEOUT, self.peripheral.write(ch, data, write_type))
            .await
            .map_err(|_| SdkError::Timeout("Omi 写入特征超时".into()))?
            .map_err(|e| SdkError::Ble(format!("Omi 写入特征失败: {e}")))
    }

    async fn probe_ring_info(&self, sdata: &Characteristic) -> Option<RingBufferInfo> {
        let mut rx = self.storage_rx.lock().await;
        while rx.try_recv().is_ok() {}
        self.write_char_auto(sdata, &[RING_CMD_INFO]).await.ok()?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        while let Ok(Some(pkt)) = tokio::time::timeout_at(deadline, rx.recv()).await {
            if let Some(info) = parse_ring_info(&pkt) {
                return Some(info);
            }
            if pkt.first().copied() == Some(RING_NOTIFY_ACK) {
                continue;
            }
            break;
        }
        None
    }
}

async fn read_optional_utf8(peripheral: &Peripheral, ch: Option<&Characteristic>) -> String {
    let Some(c) = ch else {
        return String::new();
    };
    match tokio::time::timeout(Duration::from_secs(2), peripheral.read(c)).await {
        Ok(Ok(bytes)) => String::from_utf8_lossy(&bytes)
            .trim_end_matches('\0')
            .trim()
            .to_string(),
        _ => String::new(),
    }
}

#[async_trait]
impl RecorderDevice for OmiDevice {
    fn device_name(&self) -> &str {
        &self.name
    }

    fn capabilities(&self) -> SdkCapabilities {
        self.caps
    }

    fn subscribe_events(&self) -> broadcast::Receiver<SdkDeviceEvent> {
        self.events_tx.subscribe()
    }

    fn subscribe_audio(&self) -> broadcast::Receiver<SdkAudioChunk> {
        self.audio_tx.subscribe()
    }

    async fn snapshot(&self) -> Result<SdkSnapshot, SdkError> {
        if !self.connected.load(Ordering::SeqCst) {
            return Err(SdkError::Disconnected);
        }
        let is_conn = tokio::time::timeout(Duration::from_secs(2), self.peripheral.is_connected())
            .await
            .ok()
            .and_then(|res| res.ok())
            .unwrap_or(false);
        if !is_conn {
            self.connected.store(false, Ordering::SeqCst);
            return Err(SdkError::Disconnected);
        }

        let realtime_enabled = self.realtime_enabled.load(Ordering::SeqCst);
        let storage_transfer_busy = self.storage_lock.try_lock().is_err();
        if !realtime_enabled && !storage_transfer_busy {
            if let Some(ref c) = self.audio_codec_char {
                if let Ok(Ok(bytes)) =
                    tokio::time::timeout(Duration::from_secs(2), self.peripheral.read(c)).await
                {
                    if let Some(&id) = bytes.first() {
                        *self.codec.lock().await = OmiAudioCodec::from_codec_id(id);
                    }
                }
            }
        }

        let battery = if realtime_enabled || storage_transfer_busy {
            let cached = self.battery_cache.lock().await.clone();
            if cached.level.is_some() || storage_transfer_busy {
                cached
            } else {
                self.read_battery_now().await
            }
        } else {
            self.read_battery_now().await
        };
        let is_recording = self.recording.load(Ordering::SeqCst);
        let session = self.active_session.lock().await.clone();

        let fallback_model = match self.variant {
            OmiHardwareVariant::Cv1 => "Omi CV1",
            OmiHardwareVariant::FriendPendant => "Friend Pendant",
        };
        Ok(SdkSnapshot {
            capabilities: self.caps,
            device_name: self.name.clone(),
            device_id: self.peripheral_id.clone(),
            fw_version: if !self.fw_version.is_empty() {
                self.fw_version.clone()
            } else if !self.model_number.is_empty() {
                self.model_number.clone()
            } else {
                fallback_model.to_string()
            },
            battery,
            storage: None,
            record: SdkRecordStatus {
                is_recording,
                realtime_enabled,
                session,
                error: None,
                reason: None,
            },
        })
    }

    async fn sync_time(&self) -> Result<Value, SdkError> {
        let epoch_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if let Some(ref tc) = self.timesync_char {
            let secs_u32 = u32::try_from(epoch_secs).unwrap_or(u32::MAX);
            self.write_char_auto(tc, &secs_u32.to_le_bytes()).await?;
        }
        Ok(json!({ "synced": true, "epoch": epoch_secs }))
    }

    async fn start_record(&self, _duration_secs: Option<u32>) -> Result<SdkRecordStatus, SdkError> {
        if !self.connected.load(Ordering::SeqCst) {
            return Err(SdkError::Disconnected);
        }
        if let Some(ref mute) = self.mute_char {
            // Omi firmware 19b10015: 0 = capture enabled (unmuted), 1 = muted
            let _ = self.write_char_auto(mute, &[0x00]).await;
        }
        let seq = self.session_seq.fetch_add(1, Ordering::Relaxed) + 1;
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let session = format!("OMI_{now_ms}_{seq}");
        *self.active_session.lock().await = Some(session.clone());
        self.recording.store(true, Ordering::SeqCst);
        let st = SdkRecordStatus {
            is_recording: true,
            realtime_enabled: self.realtime_enabled.load(Ordering::SeqCst),
            session: Some(session),
            error: None,
            reason: Some("app".into()),
        };
        let _ = self.events_tx.send(SdkDeviceEvent::RecordStatus(st.clone()));
        Ok(st)
    }

    async fn stop_record(&self) -> Result<SdkRecordStatus, SdkError> {
        if let Some(ref mute) = self.mute_char {
            let _ = self.write_char_auto(mute, &[0x01]).await;
        }
        self.recording.store(false, Ordering::SeqCst);
        *self.active_session.lock().await = None;
        let st = SdkRecordStatus {
            is_recording: false,
            realtime_enabled: self.realtime_enabled.load(Ordering::SeqCst),
            session: None,
            error: None,
            reason: Some("app".into()),
        };
        let _ = self.events_tx.send(SdkDeviceEvent::RecordStatus(st.clone()));
        Ok(st)
    }

    async fn set_realtime_enabled(&self, enabled: bool) -> Result<(), SdkError> {
        if !self.connected.load(Ordering::SeqCst) {
            return Err(SdkError::Disconnected);
        }
        if enabled {
            tokio::time::timeout(BLE_GATT_TIMEOUT, self.peripheral.subscribe(&self.audio_data_char))
                .await
                .map_err(|_| SdkError::Timeout("订阅 Omi 音频流超时".into()))?
                .map_err(|e| {
                    log::info!("omi audio: subscribe 失败: {e}");
                    SdkError::Ble(format!("订阅 Omi 音频流失败: {e}"))
                })?;
            log::info!("omi audio: subscribe OK（等待通知…）");
        } else {
            let _ = tokio::time::timeout(
                BLE_GATT_TIMEOUT,
                self.peripheral.unsubscribe(&self.audio_data_char),
            )
            .await;
            log::info!("omi audio: unsubscribe");
        }
        self.realtime_enabled.store(enabled, Ordering::SeqCst);
        Ok(())
    }

    async fn list_files(&self) -> Result<Vec<SdkFileEntry>, SdkError> {
        if !self.connected.load(Ordering::SeqCst) {
            return Err(SdkError::Disconnected);
        }
        let Some(ref sdata) = self.storage_data_char else {
            return Ok(Vec::new());
        };
        let _guard = self.storage_lock.lock().await;
        let mut entries = Vec::new();
        let mut handles = HashMap::new();

        // 1) 优先探测 Ring Buffer (FW 3.0.20+) 与 Multi-File (0x10)
        //    单次按 RING_RECORDS_PER_CHUNK（默认 1,800 条 ≈ 5 分钟）拆块，防止多小时积压拉取超时与 OOM，
        //    同时保持 start_at/created_at 为 None 以沿用从旧到新顺序逐块下载并推进游标。
        if let Some(info) = self.probe_ring_info(sdata).await {
            for (chunk_idx, (chunk_start, chunk_end)) in
                plan_ring_chunks(info.read_seq, info.write_seq, RING_RECORDS_PER_CHUNK)
                    .into_iter()
                    .enumerate()
            {
                let name = format!("OMI_RING_{chunk_start}_{chunk_end}.wav");
                let est_size = chunk_end
                    .saturating_sub(chunk_start)
                    .saturating_mul(u64::from(info.packet_size));
                handles.insert(
                    name.clone(),
                    OmiStorageHandle::Ring {
                        read_seq: chunk_start,
                        write_seq: chunk_end,
                    },
                );
                entries.push(SdkFileEntry {
                    name,
                    size: est_size,
                    index: u32::try_from(chunk_idx).ok(),
                    created_at: None,
                    session: None,
                    seq: u32::try_from(chunk_start).ok(),
                    start_at: None,
                    synced: Some(false),
                });
            }
            *self.storage_index.lock().await = handles;
            return Ok(entries);
        }

        // 2) 检查 Multi-File `0x10` 列表响应
        {
            let mut rx = self.storage_rx.lock().await;
            while rx.try_recv().is_ok() {}
            let _ = self.write_char_auto(sdata, &[RING_CMD_INFO]).await;
            if let Ok(Some(pkt)) =
                tokio::time::timeout(Duration::from_secs(3), rx.recv()).await
            {
                if let Some(mfiles) = parse_multi_file_list(&pkt) {
                    for mf in mfiles {
                        if mf.size_bytes == 0 {
                            continue;
                        }
                        let name = format!("OMI_SD_{}_{}.wav", mf.index, mf.timestamp);
                        let ts_opt = if mf.timestamp > 1_700_000_000 {
                            Some(i64::from(mf.timestamp))
                        } else {
                            None
                        };
                        handles.insert(name.clone(), OmiStorageHandle::MultiFile(mf.clone()));
                        entries.push(SdkFileEntry {
                            name,
                            size: u64::from(mf.size_bytes),
                            index: Some(u32::from(mf.index)),
                            created_at: ts_opt,
                            session: None,
                            seq: Some(u32::from(mf.index)),
                            start_at: ts_opt,
                            synced: Some(false),
                        });
                    }
                    *self.storage_index.lock().await = handles;
                    return Ok(entries);
                }
            }
        }

        // 3) Fallback: Legacy 单文件存储统计 `30295782` ([totalBytes: u32 LE, offset: u32 LE])
        if let Some(ref sctrl) = self.storage_ctrl_char {
            if let Ok(Ok(raw)) =
                tokio::time::timeout(Duration::from_secs(2), self.peripheral.read(sctrl)).await
            {
                if raw.len() >= 8 {
                    let total_bytes = u32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]);
                    let offset = u32::from_le_bytes([raw[4], raw[5], raw[6], raw[7]]);
                    // 避免把 FW 3.0.20 16B status 的 field[1]=fileCount 误判为 Legacy offset
                    if total_bytes > offset && (raw.len() < 16 || offset > 1000) {
                        let name = format!("OMI_SD_0_{offset}_{total_bytes}.wav");
                        handles.insert(
                            name.clone(),
                            OmiStorageHandle::Legacy {
                                offset,
                                total_bytes,
                            },
                        );
                        entries.push(SdkFileEntry {
                            name,
                            size: u64::from(total_bytes - offset),
                            index: Some(0),
                            created_at: None,
                            session: None,
                            seq: Some(0),
                            start_at: None,
                            synced: Some(false),
                        });
                    }
                }
            }
        }

        *self.storage_index.lock().await = handles;
        Ok(entries)
    }

    async fn download_file(&self, name: &str, dir: &str) -> Result<SdkSavedFile, SdkError> {
        let Some(ref sdata) = self.storage_data_char else {
            return Err(SdkError::Unsupported("当前 Omi 设备未挂载离线存储".into()));
        };
        let handle = match self.storage_index.lock().await.get(name).cloned() {
            Some(h) => h,
            None => match parse_ring_chunk_filename(name) {
                Some((read_seq, write_seq)) => OmiStorageHandle::Ring {
                    read_seq,
                    write_seq,
                },
                None => return Err(SdkError::Protocol(format!("未找到 Omi 离线记录: {name}"))),
            },
        };

        let _guard = self.storage_lock.lock().await;
        let codec = *self.codec.lock().await;
        let segments: Vec<RingTimedSegment> = match handle {
            OmiStorageHandle::Ring {
                read_seq,
                write_seq,
            } => {
                let count = u32::try_from(write_seq.saturating_sub(read_seq))
                    .unwrap_or(RING_RECORDS_PER_CHUNK);
                let mut cmd = Vec::with_capacity(13);
                cmd.push(RING_CMD_READ);
                cmd.extend_from_slice(&read_seq.to_be_bytes());
                cmd.extend_from_slice(&count.to_be_bytes());

                let mut rx = self.storage_rx.lock().await;
                while rx.try_recv().is_ok() {}
                self.write_char_auto(sdata, &cmd).await?;

                let mut raw = Vec::new();
                loop {
                    match tokio::time::timeout(Duration::from_secs(12), rx.recv()).await {
                        Ok(Some(pkt)) if !pkt.is_empty() => match pkt[0] {
                            RING_NOTIFY_DATA => raw.extend_from_slice(&pkt[1..]),
                            RING_NOTIFY_DONE => break,
                            RING_NOTIFY_ACK if pkt.len() >= 2 && pkt[1] != 0 => {
                                return Err(SdkError::Protocol(format!(
                                    "Omi Ring 读取被拒 (status=0x{:02X})",
                                    pkt[1]
                                )));
                            }
                            _ => continue,
                        },
                        Ok(Some(_)) => continue,
                        Ok(None) => return Err(SdkError::Disconnected),
                        Err(_) => break,
                    }
                }
                split_ring_encoded_segments(&raw, 60)
            }
            OmiStorageHandle::MultiFile(mf) => {
                let mut rx = self.storage_rx.lock().await;
                while rx.try_recv().is_ok() {}
                let cmd = [0x00u8, mf.index, 0, 0, 0, 0];
                self.write_char_auto(sdata, &cmd).await?;
                let mut frames = Vec::new();
                loop {
                    match tokio::time::timeout(Duration::from_secs(8), rx.recv()).await {
                        Ok(Some(pkt)) => {
                            if pkt.len() == 1 && pkt[0] != 0 {
                                break;
                            }
                            if pkt.len() == 83 {
                                let len = usize::from(pkt[3]);
                                if len > 0 && 4 + len <= pkt.len() {
                                    frames.push(pkt[4..4 + len].to_vec());
                                }
                            } else if pkt.len() >= 440 {
                                extract_len_prefixed_frames(&pkt, &mut frames);
                            }
                        }
                        Ok(None) => return Err(SdkError::Disconnected),
                        Err(_) => break,
                    }
                }
                let _ = self.write_char_auto(sdata, &[RING_CMD_STOP]).await;
                let ts_opt = is_plausible_unix_sec(mf.timestamp).then_some(mf.timestamp);
                vec![RingTimedSegment {
                    start_ts: ts_opt,
                    end_ts: ts_opt,
                    frames,
                }]
            }
            OmiStorageHandle::Legacy { offset, .. } => {
                let mut rx = self.storage_rx.lock().await;
                while rx.try_recv().is_ok() {}
                let cmd = [
                    0x00u8,
                    0x00u8,
                    ((offset >> 24) & 0xFF) as u8,
                    ((offset >> 16) & 0xFF) as u8,
                    ((offset >> 8) & 0xFF) as u8,
                    (offset & 0xFF) as u8,
                ];
                self.write_char_auto(sdata, &cmd).await?;
                let mut frames = Vec::new();
                loop {
                    match tokio::time::timeout(Duration::from_secs(8), rx.recv()).await {
                        Ok(Some(pkt)) => {
                            if pkt.len() == 1 && pkt[0] != 0 {
                                break;
                            }
                            if pkt.len() == 83 {
                                let len = usize::from(pkt[3]);
                                if len > 0 && 4 + len <= pkt.len() {
                                    frames.push(pkt[4..4 + len].to_vec());
                                }
                            } else if pkt.len() >= 440 {
                                extract_len_prefixed_frames(&pkt, &mut frames);
                            }
                        }
                        Ok(None) => return Err(SdkError::Disconnected),
                        Err(_) => break,
                    }
                }
                vec![RingTimedSegment {
                    start_ts: None,
                    end_ts: None,
                    frames,
                }]
            }
        };

        let out_dir = PathBuf::from(dir);
        tokio::fs::create_dir_all(&out_dir).await?;
        let stem = name
            .strip_suffix(".wav")
            .or_else(|| name.strip_suffix(".WAV"))
            .unwrap_or(name);

        if segments.is_empty() {
            let (dest, bytes_written) = write_omi_wav_segment(&out_dir, name, codec, &[]).await?;
            return Ok(SdkSavedFile {
                path: dest,
                bytes_written,
                original_name: name.to_string(),
                device_name: Some(self.name.clone()),
                start_at: None,
                time_synced: Some(false),
                parts: Vec::new(),
            });
        }

        let mut parts: Vec<SdkSavedFilePart> = Vec::with_capacity(segments.len());
        for (idx, seg) in segments.iter().enumerate() {
            let file_name = if idx == 0 {
                name.to_string()
            } else {
                format!("{stem}_p{idx}.wav")
            };
            let (dest, bytes_written) =
                write_omi_wav_segment(&out_dir, &file_name, codec, &seg.frames).await?;
            let start_at = seg.start_ts.map(i64::from);
            let time_synced = Some(start_at.is_some());
            parts.push(SdkSavedFilePart {
                path: dest,
                bytes_written,
                original_name: file_name,
                start_at,
                time_synced,
            });
        }

        let first = &parts[0];
        let extra_parts = if parts.len() > 1 {
            parts.clone()
        } else {
            Vec::new()
        };
        Ok(SdkSavedFile {
            path: first.path.clone(),
            bytes_written: first.bytes_written,
            original_name: name.to_string(),
            device_name: Some(self.name.clone()),
            start_at: first.start_at,
            time_synced: first.time_synced,
            parts: extra_parts,
        })
    }

    async fn delete_file(&self, name: &str) -> Result<(), SdkError> {
        let Some(ref sdata) = self.storage_data_char else {
            return Ok(());
        };
        let handle = match self.storage_index.lock().await.get(name).cloned() {
            Some(h) => Some(h),
            None => parse_ring_chunk_filename(name)
                .map(|(read_seq, write_seq)| OmiStorageHandle::Ring { read_seq, write_seq }),
        };
        let _guard = self.storage_lock.lock().await;
        match handle {
            Some(OmiStorageHandle::Ring { write_seq, .. }) => {
                let mut cmd = Vec::with_capacity(9);
                cmd.push(RING_CMD_ADVANCE);
                cmd.extend_from_slice(&write_seq.to_be_bytes());
                self.write_char_auto(sdata, &cmd).await?;
            }
            Some(OmiStorageHandle::MultiFile(mf)) => {
                self.write_char_auto(sdata, &[0x12, mf.index]).await?;
            }
            Some(OmiStorageHandle::Legacy { total_bytes, .. }) => {
                let cmd = [
                    0x01u8,
                    0x00u8,
                    ((total_bytes >> 24) & 0xFF) as u8,
                    ((total_bytes >> 16) & 0xFF) as u8,
                    ((total_bytes >> 8) & 0xFF) as u8,
                    (total_bytes & 0xFF) as u8,
                ];
                self.write_char_auto(sdata, &cmd).await?;
            }
            None => {}
        }
        self.storage_index.lock().await.remove(name);
        Ok(())
    }

    async fn disconnect(&self) -> Result<(), SdkError> {
        self.connected.store(false, Ordering::SeqCst);
        self.realtime_enabled.store(false, Ordering::SeqCst);
        self.recording.store(false, Ordering::SeqCst);
        if let Some(handle) = self.pump_task.lock().await.take() {
            handle.abort();
        }
        let is_conn =
            tokio::time::timeout(Duration::from_millis(500), self.peripheral.is_connected())
                .await
                .ok()
                .and_then(|res| res.ok())
                .unwrap_or(false);
        if is_conn {
            let unsub_deadline = tokio::time::Instant::now() + Duration::from_millis(950);
            let mut chars = Vec::with_capacity(5);
            chars.push(&self.audio_data_char);
            if let Some(ref c) = self.battery_char {
                chars.push(c);
            }
            if let Some(ref c) = self.charging_char {
                chars.push(c);
            }
            if let Some(ref c) = self.button_char {
                chars.push(c);
            }
            if let Some(ref c) = self.storage_data_char {
                chars.push(c);
            }
            for ch in chars {
                let remaining = unsub_deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    break;
                }
                let _ = tokio::time::timeout(
                    remaining.min(Duration::from_millis(250)),
                    self.peripheral.unsubscribe(ch),
                )
                .await;
            }
        }
        match tokio::time::timeout(Duration::from_millis(2800), self.peripheral.disconnect()).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) if is_conn => Err(SdkError::Ble(e.to_string())),
            Ok(Err(_)) | Err(_) => {
                log::info!("omi disconnect: CoreBluetooth 释放超时或已断连，已完成本地清理");
                Ok(())
            }
        }
    }
}

async fn write_omi_wav_segment(
    out_dir: &Path,
    file_name: &str,
    codec: OmiAudioCodec,
    encoded_frames: &[Vec<u8>],
) -> Result<(PathBuf, u64), SdkError> {
    let mut dec = OmiFrameDecoder::for_codec(codec)?;
    let mut all_pcm = Vec::new();
    for frame in encoded_frames {
        if let Ok(samples) = dec.decode_frame(frame) {
            all_pcm.extend_from_slice(&samples);
        }
    }
    let dest = out_dir.join(file_name);
    let part_dest = out_dir.join(format!("{file_name}.part"));
    if let Err(err) = write_wav_16k_mono(&part_dest, &all_pcm) {
        let _ = tokio::fs::remove_file(&part_dest).await;
        return Err(err);
    }
    tokio::fs::rename(&part_dest, &dest).await?;
    let bytes_written = tokio::fs::metadata(&dest)
        .await
        .map(|m| m.len())
        .unwrap_or((all_pcm.len() * 2 + 44) as u64);
    Ok((dest, bytes_written))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn omi_capabilities_disable_voice_key_and_expose_configurable_buttons() {
        let caps = OmiSdkDriver::capabilities(true, true);
        assert!(!caps.has_voice_key, "Omi 长按 3 秒硬关机，必须禁用语音按键");
        assert!(caps.has_mark_button);
        assert!(caps.has_configurable_buttons);
        assert!(caps.has_onboard_storage);
        assert!(caps.has_file_sync);
        assert!(!caps.has_camera_media);

        let no_btn = OmiSdkDriver::capabilities(true, false);
        assert!(!no_btn.has_voice_key);
        assert!(!no_btn.has_mark_button);
        assert!(!no_btn.has_configurable_buttons);
    }

    #[test]
    fn plans_ring_chunks_within_bound_and_parses_filenames() {
        assert!(plan_ring_chunks(100, 100, RING_RECORDS_PER_CHUNK).is_empty());
        assert!(plan_ring_chunks(120, 100, RING_RECORDS_PER_CHUNK).is_empty());
        assert_eq!(plan_ring_chunks(10, 500, 1800), vec![(10, 500)]);
        assert_eq!(
            plan_ring_chunks(100, 4000, 1800),
            vec![(100, 1900), (1900, 3700), (3700, 4000)]
        );

        assert_eq!(parse_ring_chunk_filename("OMI_RING_100_1900.wav"), Some((100, 1900)));
        assert_eq!(parse_ring_chunk_filename("OMI_RING_0_42.WAV"), Some((0, 42)));
        assert_eq!(parse_ring_chunk_filename("OMI_RING_10_10.wav"), None);
        assert_eq!(parse_ring_chunk_filename("OMI_SD_0_100.wav"), None);
    }
}
