//! 讯飞智能录音笔 A1 GATT 会话实现，统一收敛为 `RecorderSdkDriver` / `RecorderDevice`。

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use btleplug::api::{CharPropFlags, Characteristic, Peripheral as _, WriteType};
use btleplug::platform::Peripheral;
use futures::StreamExt;
use reai_ext_sdk::sbc::{sbc_bytes_to_wav_file_16k_mono, SbcDecoder};
use reai_ext_sdk::{
    RecorderDevice, RecorderSdkDriver, SdkAudioChunk, SdkBattery, SdkCapabilities, SdkDeviceEvent,
    SdkError, SdkFileEntry, SdkRecordStatus, SdkSavedFile, SdkSnapshot, SdkStorage,
};
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, Mutex as AsyncMutex};
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::protocol::{
    self, A1DeviceInfo, A1FileItem, AudioPacket, BinaryFrameAssembler, JsonNotifyAssembler,
    CHAR_AUDIO_NOTIFY_UUID, CHAR_CMD_NOTIFY_UUID, CHAR_CMD_WRITE_UUID, DEFAULT_HANDSHAKE_USER_ID,
    OPT_DELETE_FILES, OPT_DEVICE_INFO, OPT_DOWNLOAD_FILE, OPT_EVT_AUTH_TIMEOUT,
    OPT_EVT_RECORD_STATE, OPT_FILE_LIST, OPT_FILE_SIZE, OPT_HANDSHAKE, OPT_HEARTBEAT,
    OPT_RECORD_CTRL, RECORD_CTRL_START, RECORD_CTRL_STOP, SERVICE_UUID, UPLOAD_CHUNK_SIZE,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(18);
const DISCOVER_TIMEOUT: Duration = Duration::from_secs(15);
const CMD_TIMEOUT: Duration = Duration::from_secs(8);
const TRANSFER_IDLE_TIMEOUT: Duration = Duration::from_secs(10);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(6);
const BATCH_CHUNKS: u32 = 4096;
const REALTIME_AGG_SAMPLES: usize = 512;

pub struct IflytekSdkDriver;

fn capabilities() -> SdkCapabilities {
    SdkCapabilities {
        device_kind: "iflytek_a1",
        display_model: "讯飞智能录音笔 A1",
        realtime_audio: true,
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

#[async_trait]
impl RecorderSdkDriver for IflytekSdkDriver {
    fn device_kind(&self) -> &'static str {
        "iflytek_a1"
    }

    fn display_model(&self) -> &'static str {
        "讯飞智能录音笔 A1"
    }

    fn default_capabilities(&self) -> SdkCapabilities {
        capabilities()
    }

    fn matches_advertisement(
        &self,
        local_name: Option<&str>,
        services: &[Uuid],
        manufacturer_data: &HashMap<u16, Vec<u8>>,
    ) -> bool {
        protocol::matches_a1_advertisement(local_name, services, manufacturer_data)
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
            "A100".to_string()
        } else {
            compact.to_ascii_uppercase()
        };
        format!("讯飞录音笔A1_{suffix}")
    }

    async fn connect(
        &self,
        peripheral: Peripheral,
        ble_name: String,
    ) -> Result<Arc<dyn RecorderDevice>, SdkError> {
        let user_id = match peripheral.properties().await {
            Ok(Some(props)) => protocol::extract_user_id_from_mfd(&props.manufacturer_data)
                .unwrap_or_else(|| DEFAULT_HANDSHAKE_USER_ID.to_string()),
            _ => DEFAULT_HANDSHAKE_USER_ID.to_string(),
        };

        let already_connected = peripheral
            .is_connected()
            .await
            .map_err(|err| SdkError::Ble(format!("检查讯飞 A1 连接状态失败: {err}")))?;
        if !already_connected {
            match tokio::time::timeout(CONNECT_TIMEOUT, peripheral.connect()).await {
                Ok(Ok(())) => {}
                Ok(Err(err)) => return Err(SdkError::Ble(format!("连接讯飞 A1 失败: {err}"))),
                Err(_) => {
                    let _ =
                        tokio::time::timeout(Duration::from_secs(2), peripheral.disconnect()).await;
                    return Err(SdkError::Timeout("讯飞智能录音笔 A1 蓝牙建连超时".into()));
                }
            }
        }

        let opened = async {
            tokio::time::timeout(DISCOVER_TIMEOUT, peripheral.discover_services())
                .await
                .map_err(|_| SdkError::Timeout("发现讯飞 A1 GATT 服务超时".into()))?
                .map_err(|err| SdkError::Ble(format!("发现讯飞 A1 GATT 服务失败: {err}")))?;

            let chars = peripheral.characteristics();
            let write_char = chars
                .iter()
                .find(|c| c.uuid == CHAR_CMD_WRITE_UUID && c.service_uuid == SERVICE_UUID)
                .or_else(|| chars.iter().find(|c| c.uuid == CHAR_CMD_WRITE_UUID))
                .cloned()
                .ok_or_else(|| SdkError::Protocol("讯飞 A1 缺少控制写特征 001120a2".into()))?;
            let cmd_notify_char = chars
                .iter()
                .find(|c| c.uuid == CHAR_CMD_NOTIFY_UUID && c.service_uuid == SERVICE_UUID)
                .or_else(|| chars.iter().find(|c| c.uuid == CHAR_CMD_NOTIFY_UUID))
                .cloned()
                .ok_or_else(|| SdkError::Protocol("讯飞 A1 缺少控制通知特征 001120a3".into()))?;
            let audio_notify_char = chars
                .iter()
                .find(|c| c.uuid == CHAR_AUDIO_NOTIFY_UUID && c.service_uuid == SERVICE_UUID)
                .or_else(|| chars.iter().find(|c| c.uuid == CHAR_AUDIO_NOTIFY_UUID))
                .cloned()
                .ok_or_else(|| SdkError::Protocol("讯飞 A1 缺少音频通知特征 001120a4".into()))?;

            let stream = peripheral
                .notifications()
                .await
                .map_err(|err| SdkError::Ble(format!("建立讯飞 A1 通知流失败: {err}")))?;
            peripheral
                .subscribe(&cmd_notify_char)
                .await
                .map_err(|err| SdkError::Ble(format!("订阅讯飞 A1 控制通知失败: {err}")))?;
            // 001120a4 无 0x2902 CCCD 描述符：Android 经 Peripheral.java null 保护启用本地通知，
            // CoreBluetooth 可能返回 "attribute could not be found" 但固件会直接上送，因此尽力订阅、不阻断。
            let _ = tokio::time::timeout(
                Duration::from_secs(2),
                peripheral.subscribe(&audio_notify_char),
            )
            .await;

            let write_type = if write_char.properties.contains(CharPropFlags::WRITE) {
                WriteType::WithResponse
            } else {
                WriteType::WithoutResponse
            };
            let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
            let (audio_tx, audio_rx) = mpsc::unbounded_channel();
            tokio::spawn(async move {
                let mut stream = stream;
                while let Some(note) = stream.next().await {
                    if note.uuid == CHAR_CMD_NOTIFY_UUID {
                        let _ = cmd_tx.send(note.value);
                    } else if note.uuid == CHAR_AUDIO_NOTIFY_UUID {
                        let _ = audio_tx.send(note.value);
                    }
                }
            });

            let ble_id = peripheral.id().to_string();
            IflytekSession::open(
                BleLink::new(peripheral.clone(), write_char, write_type),
                ble_name,
                ble_id,
                user_id,
                cmd_rx,
                audio_rx,
            )
            .await
        }
        .await;

        match opened {
            Ok(session) => Ok(session),
            Err(err) => {
                let _ = tokio::time::timeout(Duration::from_secs(2), peripheral.disconnect()).await;
                Err(err)
            }
        }
    }
}

#[async_trait]
trait IflytekLink: Send + Sync {
    async fn write_cmd(&self, bytes: &[u8]) -> Result<(), SdkError>;
    async fn disconnect(&self) -> Result<(), SdkError>;
}

struct BleLink {
    peripheral: Peripheral,
    write_char: Characteristic,
    write_type: WriteType,
}

impl BleLink {
    fn new(peripheral: Peripheral, write_char: Characteristic, write_type: WriteType) -> Self {
        Self {
            peripheral,
            write_char,
            write_type,
        }
    }
}

#[async_trait]
impl IflytekLink for BleLink {
    async fn write_cmd(&self, bytes: &[u8]) -> Result<(), SdkError> {
        for chunk in bytes.chunks(180) {
            tokio::time::timeout(
                Duration::from_secs(5),
                self.peripheral.write(&self.write_char, chunk, self.write_type),
            )
            .await
            .map_err(|_| SdkError::Timeout("写入讯飞 A1 控制指令超时".into()))?
            .map_err(|err| SdkError::Ble(format!("写入讯飞 A1 控制指令失败: {err}")))?;
        }
        Ok(())
    }

    async fn disconnect(&self) -> Result<(), SdkError> {
        self.peripheral
            .disconnect()
            .await
            .map_err(|err| SdkError::Ble(format!("断开讯飞 A1 失败: {err}")))
    }
}

#[cfg(test)]
struct MemLink {
    tx: mpsc::UnboundedSender<Vec<u8>>,
}

#[cfg(test)]
#[async_trait]
impl IflytekLink for MemLink {
    async fn write_cmd(&self, bytes: &[u8]) -> Result<(), SdkError> {
        self.tx.send(bytes.to_vec()).map_err(|_| SdkError::Disconnected)
    }

    async fn disconnect(&self) -> Result<(), SdkError> {
        Ok(())
    }
}

struct FileTransferSlot {
    opt_num: u32,
    tx: mpsc::UnboundedSender<AudioPacket>,
}

struct SessionShared {
    pending: Mutex<BTreeMap<(u32, u32), mpsc::UnboundedSender<Value>>>,
    file_slot: Mutex<Option<FileTransferSlot>>,
    realtime_enabled: AtomicBool,
    realtime_reset_needed: AtomicBool,
    active_recording: AtomicBool,
    active_record_file: Mutex<Option<String>>,
    last_info: Mutex<Option<A1DeviceInfo>>,
    events_tx: broadcast::Sender<SdkDeviceEvent>,
    audio_tx: broadcast::Sender<SdkAudioChunk>,
    closed: AtomicBool,
}

impl SessionShared {
    fn fail_all(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.pending.lock().expect("pending").clear();
        *self.file_slot.lock().expect("file_slot") = None;
        let _ = self.events_tx.send(SdkDeviceEvent::Disconnected);
    }

    fn route_json(&self, msg: Value) {
        let opt = msg.get("opt").and_then(Value::as_u64).unwrap_or(0) as u32;
        let opt_num = msg.get("optNum").and_then(Value::as_u64).unwrap_or(0) as u32;

        if opt == OPT_EVT_RECORD_STATE {
            let status = msg.get("status").and_then(Value::as_i64).unwrap_or(0);
            let file_name = msg
                .get("fileName")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            let is_recording = status == 1;
            self.active_recording.store(is_recording, Ordering::SeqCst);
            *self.active_record_file.lock().expect("rec_file") = if is_recording {
                file_name.clone()
            } else {
                None
            };
            let _ = self
                .events_tx
                .send(SdkDeviceEvent::RecordStatus(SdkRecordStatus {
                    is_recording,
                    realtime_enabled: self.realtime_enabled.load(Ordering::Relaxed),
                    session: file_name,
                    error: None,
                    reason: None,
                }));
            return;
        }

        if opt == OPT_EVT_AUTH_TIMEOUT {
            self.fail_all();
            return;
        }

        let sender = self
            .pending
            .lock()
            .expect("pending")
            .get(&(opt, opt_num))
            .cloned();
        if let Some(tx) = sender {
            let _ = tx.send(msg);
        }
    }
}

struct PendingGuard<'a> {
    shared: &'a SessionShared,
    key: (u32, u32),
}

impl Drop for PendingGuard<'_> {
    fn drop(&mut self) {
        self.shared.pending.lock().expect("pending").remove(&self.key);
    }
}

struct FileSlotGuard<'a> {
    shared: &'a SessionShared,
}

impl Drop for FileSlotGuard<'_> {
    fn drop(&mut self) {
        *self.shared.file_slot.lock().expect("file_slot") = None;
    }
}

struct IflytekSession<L: IflytekLink> {
    link: L,
    name: String,
    ble_id: String,
    shared: Arc<SessionShared>,
    opt_seq: AtomicU32,
    list_lock: AsyncMutex<()>,
    transfer_lock: AsyncMutex<()>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
}

impl<L: IflytekLink> Drop for IflytekSession<L> {
    fn drop(&mut self) {
        self.shared.closed.store(true, Ordering::SeqCst);
        let mut guard = self.tasks.lock().expect("tasks");
        for handle in guard.drain(..) {
            handle.abort();
        }
    }
}

impl<L: IflytekLink + 'static> IflytekSession<L> {
    async fn open(
        link: L,
        ble_name: String,
        ble_id: String,
        user_id: String,
        cmd_rx: mpsc::UnboundedReceiver<Vec<u8>>,
        audio_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    ) -> Result<Arc<Self>, SdkError> {
        let (events_tx, _) = broadcast::channel(64);
        let (audio_tx, _) = broadcast::channel(256);
        let shared = Arc::new(SessionShared {
            pending: Mutex::new(BTreeMap::new()),
            file_slot: Mutex::new(None),
            realtime_enabled: AtomicBool::new(false),
            realtime_reset_needed: AtomicBool::new(false),
            active_recording: AtomicBool::new(false),
            active_record_file: Mutex::new(None),
            last_info: Mutex::new(None),
            events_tx,
            audio_tx,
            closed: AtomicBool::new(false),
        });

        let cmd_task = spawn_cmd_pump(shared.clone(), cmd_rx);
        let audio_task = spawn_audio_pump(shared.clone(), audio_rx);

        let session = Arc::new(Self {
            link,
            name: ble_name,
            ble_id,
            shared: shared.clone(),
            opt_seq: AtomicU32::new(1),
            list_lock: AsyncMutex::new(()),
            transfer_lock: AsyncMutex::new(()),
            tasks: Mutex::new(vec![cmd_task, audio_task]),
        });

        // 8 秒内完成 62012 握手；失败直接报错并断开
        session.handshake(&user_id).await?;
        let _ = session.sync_time().await;
        let _ = session.query_device_info().await?;

        let keepalive_session = Arc::downgrade(&session);
        let keepalive_task = tokio::spawn(async move {
            let mut interval = tokio::time::interval(KEEPALIVE_INTERVAL);
            interval.tick().await;
            loop {
                interval.tick().await;
                let Some(sess) = keepalive_session.upgrade() else {
                    break;
                };
                if sess.shared.closed.load(Ordering::Acquire) {
                    break;
                }
                if sess.transfer_lock.try_lock().is_err() {
                    continue;
                }
                let opt_num = sess.next_opt_num();
                let _ = sess
                    .send_single(OPT_HEARTBEAT, opt_num, &json!({
                        "opt": OPT_HEARTBEAT,
                        "optNum": opt_num,
                    }))
                    .await;
            }
        });
        session.tasks.lock().expect("tasks").push(keepalive_task);

        Ok(session)
    }

    fn next_opt_num(&self) -> u32 {
        loop {
            let v = self.opt_seq.fetch_add(1, Ordering::Relaxed);
            let wrapped = (v % 65533) + 1;
            if wrapped != 65535 {
                return wrapped;
            }
        }
    }

    async fn send_raw_expect_many(
        &self,
        opt: u32,
        opt_num: u32,
        raw_bytes: &[u8],
    ) -> Result<(mpsc::UnboundedReceiver<Value>, PendingGuard<'_>), SdkError> {
        if self.shared.closed.load(Ordering::Acquire) {
            return Err(SdkError::Disconnected);
        }
        let (tx, rx) = mpsc::unbounded_channel();
        self.shared
            .pending
            .lock()
            .expect("pending")
            .insert((opt, opt_num), tx);
        let guard = PendingGuard {
            shared: &self.shared,
            key: (opt, opt_num),
        };
        self.link.write_cmd(raw_bytes).await?;
        Ok((rx, guard))
    }

    async fn send_single(&self, opt: u32, opt_num: u32, body: &Value) -> Result<Value, SdkError> {
        let encoded = protocol::encode_json_command(body);
        self.send_raw_single(opt, opt_num, &encoded).await
    }

    async fn send_raw_single(
        &self,
        opt: u32,
        opt_num: u32,
        raw_bytes: &[u8],
    ) -> Result<Value, SdkError> {
        let (mut rx, _guard) = self.send_raw_expect_many(opt, opt_num, raw_bytes).await?;
        let resp = match tokio::time::timeout(CMD_TIMEOUT, rx.recv()).await {
            Ok(Some(val)) => val,
            Ok(None) => return Err(SdkError::Disconnected),
            Err(_) => {
                return Err(SdkError::Timeout(format!(
                    "讯飞 A1 指令 opt={opt} 响应超时"
                )))
            }
        };
        check_err_code(&resp, opt)?;
        Ok(resp)
    }

    async fn handshake(&self, user_id: &str) -> Result<(), SdkError> {
        let opt_num = self.next_opt_num();
        let bytes = protocol::build_handshake_command(opt_num, user_id);
        self.send_raw_single(OPT_HANDSHAKE, opt_num, &bytes).await?;
        Ok(())
    }

    async fn query_device_info(&self) -> Result<A1DeviceInfo, SdkError> {
        let opt_num = self.next_opt_num();
        let resp = self
            .send_single(
                OPT_DEVICE_INFO,
                opt_num,
                &json!({
                    "opt": OPT_DEVICE_INFO,
                    "optNum": opt_num,
                }),
            )
            .await?;
        let info: A1DeviceInfo = serde_json::from_value(resp)
            .map_err(|e| SdkError::Protocol(format!("解析讯飞 A1 状态响应失败: {e}")))?;
        let is_rec = info.rec_sta == 1;
        self.shared.active_recording.store(is_rec, Ordering::SeqCst);
        *self.shared.active_record_file.lock().expect("rec_file") = if is_rec {
            let rf = info.rec_file_name.trim();
            (!rf.is_empty()).then(|| rf.to_string())
        } else {
            None
        };
        *self.shared.last_info.lock().expect("last_info") = Some(info.clone());
        Ok(info)
    }

    async fn cancel_download_quietly(&self, file_name: &str) {
        let opt_num = self.next_opt_num();
        let body = json!({
            "opt": OPT_DOWNLOAD_FILE,
            "optNum": opt_num,
            "fileName": file_name,
            "startChunk": -1,
            "uploadChunkSize": UPLOAD_CHUNK_SIZE,
        });
        let _ = self.link.write_cmd(&protocol::encode_json_command(&body)).await;
    }

    async fn query_file_size(&self, file_name: &str) -> Result<u64, SdkError> {
        let opt_num = self.next_opt_num();
        let resp = self
            .send_single(
                OPT_FILE_SIZE,
                opt_num,
                &json!({
                    "opt": OPT_FILE_SIZE,
                    "optNum": opt_num,
                    "fileName": file_name,
                }),
            )
            .await?;
        let size = resp.get("size").and_then(Value::as_u64).unwrap_or(0);
        if size == 0 {
            return Err(SdkError::Protocol(format!(
                "录音文件 {file_name} 大小为空或不存在"
            )));
        }
        Ok(size)
    }
}

fn check_err_code(resp: &Value, opt: u32) -> Result<(), SdkError> {
    let err_code = resp.get("errCode").and_then(Value::as_i64).unwrap_or(0);
    if err_code != 0 {
        return Err(SdkError::Protocol(format!(
            "讯飞 A1 返回错误: opt={opt}, errCode={err_code}"
        )));
    }
    Ok(())
}

fn spawn_cmd_pump(
    shared: Arc<SessionShared>,
    mut cmd_rx: mpsc::UnboundedReceiver<Vec<u8>>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut assembler = JsonNotifyAssembler::new();
        while let Some(chunk) = cmd_rx.recv().await {
            if shared.closed.load(Ordering::Acquire) {
                break;
            }
            for msg in assembler.feed(&chunk) {
                shared.route_json(msg);
            }
        }
        shared.fail_all();
    })
}

fn spawn_audio_pump(
    shared: Arc<SessionShared>,
    mut audio_rx: mpsc::UnboundedReceiver<Vec<u8>>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut assembler = BinaryFrameAssembler::new();
        let mut decoder = SbcDecoder::new();
        let mut pcm_buf: Vec<i16> = Vec::with_capacity(REALTIME_AGG_SAMPLES);
        let mut last_seq: Option<u32> = None;

        while let Some(chunk) = audio_rx.recv().await {
            if shared.closed.load(Ordering::Acquire) {
                break;
            }
            for pkt in assembler.feed(&chunk) {
                match pkt {
                    AudioPacket::FileChunk {
                        opt_num,
                        total_chunks,
                        chunk_id,
                        is_last,
                        data,
                    } => {
                        let tx = shared
                            .file_slot
                            .lock()
                            .expect("file_slot")
                            .as_ref()
                            .filter(|slot| opt_num == 0 || slot.opt_num == opt_num)
                            .map(|slot| slot.tx.clone());
                        if let Some(tx) = tx {
                            let _ = tx.send(AudioPacket::FileChunk {
                                opt_num,
                                total_chunks,
                                chunk_id,
                                is_last,
                                data,
                            });
                        }
                    }
                    AudioPacket::RealtimeSbc { seq, sbc_frame } => {
                        if !shared.realtime_enabled.load(Ordering::Acquire) {
                            continue;
                        }
                        if shared.realtime_reset_needed.swap(false, Ordering::SeqCst) {
                            decoder.reset();
                            pcm_buf.clear();
                            last_seq = None;
                        }
                        let gap = last_seq.is_some_and(|prev| prev.wrapping_add(1) != seq);
                        last_seq = Some(seq);
                        if gap && !pcm_buf.is_empty() {
                            let _ = shared.audio_tx.send(SdkAudioChunk {
                                samples: std::mem::take(&mut pcm_buf),
                                sample_rate: 16_000,
                                channels: 1,
                                discontinuous: false,
                            });
                        }
                        match decoder.decode_frame(&sbc_frame) {
                            Ok((samples, _)) => {
                                if gap {
                                    let _ = shared.audio_tx.send(SdkAudioChunk {
                                        samples,
                                        sample_rate: 16_000,
                                        channels: 1,
                                        discontinuous: true,
                                    });
                                } else {
                                    pcm_buf.extend_from_slice(&samples);
                                    if pcm_buf.len() >= REALTIME_AGG_SAMPLES {
                                        let _ = shared.audio_tx.send(SdkAudioChunk {
                                            samples: std::mem::take(&mut pcm_buf),
                                            sample_rate: 16_000,
                                            channels: 1,
                                            discontinuous: false,
                                        });
                                    }
                                }
                            }
                            Err(err) => {
                                log::debug!("[iflytek-a1] 实时 SBC 帧解码跳过 seq={seq}: {err}");
                                if !pcm_buf.is_empty() {
                                    let _ = shared.audio_tx.send(SdkAudioChunk {
                                        samples: std::mem::take(&mut pcm_buf),
                                        sample_rate: 16_000,
                                        channels: 1,
                                        discontinuous: true,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
        shared.fail_all();
    })
}

fn sanitize_a1_file_name(raw_name: &str) -> Result<String, SdkError> {
    let base = raw_name
        .trim()
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(raw_name)
        .trim();
    if base.is_empty() || base == "." || base == ".." {
        return Err(SdkError::Protocol(format!("非法 A1 文件名: {raw_name:?}")));
    }
    if base.to_ascii_lowercase().ends_with(".sbc") {
        Ok(base.to_string())
    } else {
        Ok(format!("{base}.sbc"))
    }
}

#[async_trait]
impl<L: IflytekLink + 'static> RecorderDevice for IflytekSession<L> {
    fn device_name(&self) -> &str {
        &self.name
    }

    fn capabilities(&self) -> SdkCapabilities {
        capabilities()
    }

    fn subscribe_events(&self) -> broadcast::Receiver<SdkDeviceEvent> {
        self.shared.events_tx.subscribe()
    }

    fn subscribe_audio(&self) -> broadcast::Receiver<SdkAudioChunk> {
        self.shared.audio_tx.subscribe()
    }

    async fn snapshot(&self) -> Result<SdkSnapshot, SdkError> {
        let info = self.query_device_info().await?;
        let total_mb = info.disk_total / (1024 * 1024);
        let free_mb = info.disk_free / (1024 * 1024);
        let used_mb = total_mb.saturating_sub(free_mb);
        let fw = if info.fw_version.trim().is_empty() {
            info.ota_version.trim().to_string()
        } else {
            info.fw_version.trim().to_string()
        };
        let device_id = if !info.sn.trim().is_empty() {
            info.sn.trim().to_string()
        } else {
            self.ble_id.clone()
        };
        let active_session = if info.rec_sta == 1 && !info.rec_file_name.trim().is_empty() {
            Some(info.rec_file_name.trim().to_string())
        } else {
            None
        };
        Ok(SdkSnapshot {
            capabilities: capabilities(),
            device_name: self.name.clone(),
            device_id,
            fw_version: fw,
            battery: SdkBattery {
                level: Some(info.bat_level.min(100)),
                is_charging: info.charging_sta != 0,
            },
            storage: (total_mb > 0).then_some(SdkStorage {
                total_mb,
                used_mb,
                free_mb,
            }),
            record: SdkRecordStatus {
                is_recording: info.rec_sta == 1,
                realtime_enabled: self.shared.realtime_enabled.load(Ordering::Relaxed),
                session: active_session,
                error: None,
                reason: None,
            },
        })
    }

    async fn sync_time(&self) -> Result<Value, SdkError> {
        let opt_num = self.next_opt_num();
        let cmd = protocol::build_sync_time_command(opt_num);
        self.send_raw_single(protocol::OPT_SYNC_TIME, opt_num, &cmd)
            .await?;
        Ok(json!({ "synced": true }))
    }

    async fn start_record(&self, _duration_secs: Option<u32>) -> Result<SdkRecordStatus, SdkError> {
        let opt_num = self.next_opt_num();
        let resp = self
            .send_single(
                OPT_RECORD_CTRL,
                opt_num,
                &json!({
                    "opt": OPT_RECORD_CTRL,
                    "optNum": opt_num,
                    "ctrl": RECORD_CTRL_START,
                }),
            )
            .await?;
        let file_name = resp
            .get("fileName")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        self.shared.active_recording.store(true, Ordering::SeqCst);
        *self.shared.active_record_file.lock().expect("rec_file") = file_name.clone();
        let status = SdkRecordStatus {
            is_recording: true,
            realtime_enabled: self.shared.realtime_enabled.load(Ordering::Relaxed),
            session: file_name,
            error: None,
            reason: None,
        };
        let _ = self
            .shared
            .events_tx
            .send(SdkDeviceEvent::RecordStatus(status.clone()));
        Ok(status)
    }

    async fn stop_record(&self) -> Result<SdkRecordStatus, SdkError> {
        let opt_num = self.next_opt_num();
        let resp = self
            .send_single(
                OPT_RECORD_CTRL,
                opt_num,
                &json!({
                    "opt": OPT_RECORD_CTRL,
                    "optNum": opt_num,
                    "ctrl": RECORD_CTRL_STOP,
                }),
            )
            .await?;
        let file_name = resp
            .get("fileName")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        self.shared.active_recording.store(false, Ordering::SeqCst);
        *self.shared.active_record_file.lock().expect("rec_file") = None;
        let status = SdkRecordStatus {
            is_recording: false,
            realtime_enabled: self.shared.realtime_enabled.load(Ordering::Relaxed),
            session: file_name,
            error: None,
            reason: None,
        };
        let _ = self
            .shared
            .events_tx
            .send(SdkDeviceEvent::RecordStatus(status.clone()));
        Ok(status)
    }

    async fn set_realtime_enabled(&self, enabled: bool) -> Result<(), SdkError> {
        if enabled {
            self.shared
                .realtime_reset_needed
                .store(true, Ordering::SeqCst);
        }
        self.shared
            .realtime_enabled
            .store(enabled, Ordering::SeqCst);
        Ok(())
    }

    async fn list_files(&self) -> Result<Vec<SdkFileEntry>, SdkError> {
        let _guard_list = self.list_lock.lock().await;
        // A1 文档/列表使用固定 optNum=65535（按实测抓包与官方 APK `Lg8/a;->o` 一致）
        let list_opt_num: u32 = 65535;
        let cmd = protocol::encode_json_command(&json!({
            "opt": OPT_FILE_LIST,
            "optNum": list_opt_num,
        }));
        let (mut rx, _pending_guard) = self
            .send_raw_expect_many(OPT_FILE_LIST, list_opt_num, &cmd)
            .await?;

        let mut collected: BTreeMap<String, A1FileItem> = BTreeMap::new();
        let mut active_recording_file: Option<String> = None;

        for _ in 0..64 {
            let page = match tokio::time::timeout(CMD_TIMEOUT, rx.recv()).await {
                Ok(Some(v)) => v,
                Ok(None) => return Err(SdkError::Disconnected),
                Err(_) => {
                    return Err(SdkError::Timeout("读取讯飞 A1 文件列表超时".into()));
                }
            };
            check_err_code(&page, OPT_FILE_LIST)?;
            if let Some(rf) = page
                .get("recFileName")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                active_recording_file = Some(rf.to_string());
            }
            if let Some(items) = page.get("list").and_then(Value::as_array) {
                for raw in items {
                    if let Ok(item) = serde_json::from_value::<A1FileItem>(raw.clone()) {
                        if !item.file_name.trim().is_empty() {
                            collected.insert(item.file_name.clone(), item);
                        }
                    }
                }
            }
            let is_last = page.get("isLast").and_then(Value::as_i64).unwrap_or(1) == 1;
            if is_last {
                let mut entries: Vec<SdkFileEntry> = collected
                    .into_values()
                    .filter(|it| {
                        active_recording_file
                            .as_deref()
                            .is_none_or(|rf| rf != it.file_name)
                    })
                    .filter(|it| it.size > 0)
                    .map(|it| {
                        let start_at = protocol::parse_a1_filename_epoch_sec(&it.file_name);
                        SdkFileEntry {
                            name: it.file_name,
                            size: it.size,
                            index: None,
                            created_at: start_at,
                            session: None,
                            seq: None,
                            start_at,
                            synced: Some(start_at.is_some()),
                        }
                    })
                    .collect();
                entries.sort_by(|a, b| a.name.cmp(&b.name));
                return Ok(entries);
            }
        }

        Err(SdkError::Protocol("讯飞 A1 文件列表页数超出预期上限".into()))
    }

    async fn download_file(&self, name: &str, dir: &str) -> Result<SdkSavedFile, SdkError> {
        let _guard_xfer = self.transfer_lock.lock().await;
        let clean_name = sanitize_a1_file_name(name)?;
        let total_size = self.query_file_size(&clean_name).await?;
        let total_chunks = total_size.div_ceil(UPLOAD_CHUNK_SIZE as u64) as u32;
        if total_chunks == 0 {
            return Err(SdkError::Protocol(format!("录音 {clean_name} 分块数为 0")));
        }

        let mut chunk_bufs: Vec<Option<Vec<u8>>> = vec![None; total_chunks as usize];
        let mut cursor = 1u32;

        while cursor <= total_chunks {
            let batch_end = (cursor.saturating_add(BATCH_CHUNKS) - 1).min(total_chunks);
            let mut batch_ok = false;

            for _attempt in 0..3 {
                // 从本批第一个尚未收齐的分块续传
                let Some(first_missing) = (cursor..=batch_end)
                    .find(|&cid| chunk_bufs[(cid - 1) as usize].is_none())
                else {
                    batch_ok = true;
                    break;
                };

                let (ftx, mut frx) = mpsc::unbounded_channel();
                let opt_num = self.next_opt_num();
                *self.shared.file_slot.lock().expect("file_slot") = Some(FileTransferSlot {
                    opt_num,
                    tx: ftx,
                });
                let _slot_guard = FileSlotGuard {
                    shared: &self.shared,
                };

                let cmd = json!({
                    "opt": OPT_DOWNLOAD_FILE,
                    "optNum": opt_num,
                    "fileName": clean_name,
                    "startChunk": first_missing,
                    "endChunk": batch_end,
                    "uploadChunkSize": UPLOAD_CHUNK_SIZE,
                });
                if let Err(err) = self.send_single(OPT_DOWNLOAD_FILE, opt_num, &cmd).await {
                    drop(_slot_guard);
                    self.cancel_download_quietly(&clean_name).await;
                    return Err(err);
                }

                let mut seen_last_flag = false;
                loop {
                    let all_filled = (first_missing..=batch_end)
                        .all(|cid| chunk_bufs[(cid - 1) as usize].is_some());
                    if all_filled {
                        batch_ok = true;
                        break;
                    }
                    match tokio::time::timeout(TRANSFER_IDLE_TIMEOUT, frx.recv()).await {
                        Ok(Some(AudioPacket::FileChunk {
                            opt_num: pkt_opt,
                            chunk_id,
                            is_last,
                            data,
                            ..
                        })) => {
                            if pkt_opt != 0 && pkt_opt != opt_num {
                                continue;
                            }
                            if chunk_id >= 1 && chunk_id <= total_chunks && !data.is_empty() {
                                let idx = (chunk_id - 1) as usize;
                                if chunk_bufs[idx].is_none() {
                                    chunk_bufs[idx] = Some(data);
                                }
                            }
                            if is_last {
                                seen_last_flag = true;
                                if (first_missing..=batch_end)
                                    .all(|cid| chunk_bufs[(cid - 1) as usize].is_some())
                                {
                                    batch_ok = true;
                                    break;
                                }
                            }
                        }
                        Ok(Some(AudioPacket::RealtimeSbc { .. })) => {}
                        Ok(None) => {
                            drop(_slot_guard);
                            return Err(SdkError::Disconnected);
                        }
                        Err(_) => {
                            // 本轮出现丢包超时：退出循环由外层从缺失处续拉
                            break;
                        }
                    }
                    if seen_last_flag
                        && !(first_missing..=batch_end)
                            .all(|cid| chunk_bufs[(cid - 1) as usize].is_some())
                    {
                        // 设备已发出 is_last 标志但仍有缺块，等待少量尾巴包后走缺块续拉
                        tokio::time::sleep(Duration::from_millis(80)).await;
                        while let Ok(AudioPacket::FileChunk {
                            opt_num: pkt_opt,
                            chunk_id,
                            data,
                            ..
                        }) = frx.try_recv()
                        {
                            if (pkt_opt == 0 || pkt_opt == opt_num)
                                && chunk_id >= 1
                                && chunk_id <= total_chunks
                                && !data.is_empty()
                            {
                                let idx = (chunk_id - 1) as usize;
                                if chunk_bufs[idx].is_none() {
                                    chunk_bufs[idx] = Some(data);
                                }
                            }
                        }
                        break;
                    }
                }
                drop(_slot_guard);
                if batch_ok {
                    break;
                }
            }

            if !batch_ok {
                self.cancel_download_quietly(&clean_name).await;
                let missing = (cursor..=batch_end)
                    .filter(|&cid| chunk_bufs[(cid - 1) as usize].is_none())
                    .count();
                return Err(SdkError::Timeout(format!(
                    "拉取讯飞 A1 文件 {clean_name} 超时（缺少 {missing} 个分块）"
                )));
            }
            cursor = batch_end + 1;
        }

        let mut raw_sbc = Vec::with_capacity(total_size as usize);
        for (idx, chunk_opt) in chunk_bufs.into_iter().enumerate() {
            let chunk = chunk_opt.ok_or_else(|| {
                SdkError::Protocol(format!("讯飞 A1 分块 #{} 缺失", idx + 1))
            })?;
            raw_sbc.extend_from_slice(&chunk);
        }
        if raw_sbc.len() > total_size as usize {
            raw_sbc.truncate(total_size as usize);
        }

        let out_dir = PathBuf::from(dir);
        std::fs::create_dir_all(&out_dir)?;
        let stem = clean_name
            .strip_suffix(".sbc")
            .or_else(|| clean_name.strip_suffix(".SBC"))
            .unwrap_or(&clean_name);
        let wav_path = out_dir.join(format!("{stem}.wav"));
        sbc_bytes_to_wav_file_16k_mono(&raw_sbc, &wav_path)?;
        let bytes_written = std::fs::metadata(&wav_path).map(|m| m.len()).unwrap_or(0);
        let start_at = protocol::parse_a1_filename_epoch_sec(&clean_name);

        Ok(SdkSavedFile {
            path: wav_path,
            bytes_written,
            original_name: clean_name,
            device_name: Some(self.name.clone()),
            start_at,
            time_synced: Some(start_at.is_some()),
            parts: Vec::new(),
        })
    }

    async fn delete_file(&self, name: &str) -> Result<(), SdkError> {
        let clean_name = sanitize_a1_file_name(name)?;
        if self.shared.active_recording.load(Ordering::Acquire) {
            let is_active = self
                .shared
                .active_record_file
                .lock()
                .expect("rec_file")
                .as_deref()
                .is_some_and(|rf| rf == clean_name);
            if is_active {
                return Err(SdkError::Protocol(format!(
                    "无法删除正在录音中的文件 {clean_name}"
                )));
            }
        }
        let opt_num = self.next_opt_num();
        self.send_single(
            OPT_DELETE_FILES,
            opt_num,
            &json!({
                "opt": OPT_DELETE_FILES,
                "optNum": opt_num,
                "list": [clean_name],
            }),
        )
        .await?;
        Ok(())
    }

    async fn disconnect(&self) -> Result<(), SdkError> {
        self.shared.fail_all();
        {
            let mut guard = self.tasks.lock().expect("tasks");
            for handle in guard.drain(..) {
                handle.abort();
            }
        }
        self.link.disconnect().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{crc8_atm, BINARY_FRAME_MAGIC};

    const REAL_A1_SBC_FRAME: [u8; 128] = [
        0x9c, 0x35, 0x1d, 0xeb, 0x66, 0x54, 0x66, 0x64, 0x66, 0x55, 0x56, 0x64, 0x8b, 0xa0, 0xec,
        0xcc, 0x4a, 0x93, 0x88, 0x22, 0xe8, 0xcc, 0xb3, 0x3b, 0x97, 0x1f, 0x2a, 0x44, 0xd3, 0x26,
        0xdf, 0x09, 0xa3, 0xa1, 0xf2, 0xf4, 0x2c, 0x51, 0xc2, 0x72, 0xd5, 0x9b, 0xa2, 0xb7, 0x8c,
        0xb0, 0x9c, 0x44, 0x66, 0xcc, 0x85, 0x33, 0x3b, 0x3a, 0xda, 0xd0, 0x3b, 0x72, 0x4d, 0x13,
        0x0e, 0x49, 0x8a, 0x2e, 0xca, 0x1d, 0x94, 0xb2, 0x25, 0x8d, 0x1a, 0xb1, 0x0c, 0xd1, 0x86,
        0xd3, 0x87, 0x56, 0xe6, 0xbb, 0x80, 0xbb, 0x12, 0x56, 0xdc, 0x4a, 0x8e, 0xef, 0x61, 0x50,
        0x49, 0x85, 0x44, 0xdd, 0x24, 0x8b, 0x12, 0x76, 0x55, 0x5b, 0x99, 0x12, 0xd3, 0x6c, 0x63,
        0x57, 0x63, 0x0e, 0x3a, 0xb3, 0x0c, 0xc8, 0x6a, 0x03, 0x4c, 0x46, 0x6e, 0x9d, 0x36, 0x28,
        0x66, 0xf8, 0x83, 0x2b, 0xb6, 0xdb, 0x6d, 0x11,
    ];

    fn make_realtime_packet(seq: u32, sbc: &[u8]) -> Vec<u8> {
        let mut p = Vec::new();
        p.extend_from_slice(&BINARY_FRAME_MAGIC);
        p.extend_from_slice(&[0, 0, 0, 0, 0x01, 0x04]);
        p.extend_from_slice(&((7 + sbc.len()) as u16).to_le_bytes());
        p.extend_from_slice(&[0x00, 0x00, 0x01, 0x01]);
        p.extend_from_slice(&seq.to_le_bytes());
        p.extend_from_slice(sbc);
        let crc = crc8_atm(&p);
        p.push(crc);
        p
    }

    fn make_file_chunk_packet(
        opt_num: u32,
        total_chunks: u32,
        chunk_id: u32,
        is_last: bool,
        slice: &[u8],
    ) -> Vec<u8> {
        let mut p = Vec::new();
        p.extend_from_slice(&BINARY_FRAME_MAGIC);
        p.extend_from_slice(&[0, 0, 0, 0, 0x01, 0x04]);
        p.extend_from_slice(&((16 + slice.len()) as u16).to_le_bytes());
        p.extend_from_slice(&[0x00, 0x00, 0x01, 0x02]);
        p.extend_from_slice(&opt_num.to_le_bytes());
        p.extend_from_slice(&total_chunks.to_le_bytes());
        p.extend_from_slice(&chunk_id.to_le_bytes());
        p.push(if is_last { 0x01 } else { 0x02 });
        p.extend_from_slice(slice);
        let crc = crc8_atm(&p);
        p.push(crc);
        p
    }

    #[tokio::test]
    async fn scripted_a1_session_handles_full_lifecycle_and_sbc_streams() {
        let (write_tx, mut write_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (audio_tx, audio_rx) = mpsc::unbounded_channel::<Vec<u8>>();

        let cmd_tx_clone = cmd_tx.clone();
        let audio_tx_clone = audio_tx.clone();
        tokio::spawn(async move {
            let mut file_bytes = Vec::with_capacity(640);
            for _ in 0..5 {
                file_bytes.extend_from_slice(&REAL_A1_SBC_FRAME);
            }
            let total_chunks = 2u32; // 512B + 128B = 640B
            let mut recording = false;
            let mut files = vec![
                ("2026_11_22_15_47_30.sbc".to_string(), file_bytes.len() as u64),
            ];
            while let Some(raw) = write_rx.recv().await {
                let s = String::from_utf8_lossy(&raw).trim_end_matches('\0').to_string();
                let req: Value = serde_json::from_str(&s).unwrap();
                let opt = req["opt"].as_u64().unwrap() as u32;
                let opt_num = req["optNum"].as_u64().unwrap() as u32;
                let resp = match opt {
                    OPT_HANDSHAKE => {
                        assert_eq!(req["userId"], DEFAULT_HANDSHAKE_USER_ID);
                        json!({"opt": OPT_HANDSHAKE, "optNum": opt_num, "errCode": 0})
                    }
                    protocol::OPT_SYNC_TIME => {
                        json!({"opt": protocol::OPT_SYNC_TIME, "optNum": opt_num, "errCode": 0})
                    }
                    OPT_DEVICE_INFO => {
                        json!({
                            "diskFree": 10032676864u64,
                            "diskTotal": 15632334848u64,
                            "diskRecTime": 209014u64,
                            "diskSta": 0,
                            "recSta": if recording { 1 } else { 0 },
                            "rttSta": 0,
                            "batLevel": 70,
                            "bleName": "讯飞录音笔A1_11E0",
                            "recFileName": if recording { "2026_11_22_20_00_00.sbc" } else { "" },
                            "otaVersion": "10029",
                            "fwVersion": "1.1.0029",
                            "sn": "H00DBB0FC011E0",
                            "blueAddr": "71E5D2FC4EF4",
                            "chargingSta": 0,
                            "powerOffTime": 5,
                            "opt": OPT_DEVICE_INFO,
                            "optNum": opt_num,
                            "errCode": 0
                        })
                    }
                    OPT_RECORD_CTRL => {
                        recording = req["ctrl"].as_i64().unwrap() == 1;
                        json!({
                            "opt": OPT_RECORD_CTRL,
                            "optNum": opt_num,
                            "errCode": 0,
                            "fileName": "2026_11_22_20_00_00.sbc"
                        })
                    }
                    OPT_FILE_LIST => {
                        let page1 = protocol::encode_json_command(&json!({
                            "opt": OPT_FILE_LIST,
                            "optNum": opt_num,
                            "errCode": 0,
                            "curChunk": 1,
                            "totalNum": files.len(),
                            "isLast": 0,
                            "recFileName": "",
                            "list": []
                        }));
                        let _ = cmd_tx_clone.send(page1);
                        json!({
                            "opt": OPT_FILE_LIST,
                            "optNum": opt_num,
                            "errCode": 0,
                            "curChunk": 2,
                            "totalNum": files.len(),
                            "isLast": 1,
                            "recFileName": "",
                            "list": files.iter().map(|(n, sz)| json!({"fileName": n, "size": sz})).collect::<Vec<_>>()
                        })
                    }
                    OPT_FILE_SIZE => {
                        let name = req["fileName"].as_str().unwrap();
                        let sz = files.iter().find(|(n, _)| n == name).map(|(_, s)| *s).unwrap_or(0);
                        json!({"opt": OPT_FILE_SIZE, "optNum": opt_num, "errCode": 0, "fileName": name, "size": sz})
                    }
                    OPT_DOWNLOAD_FILE => {
                        let start = req["startChunk"].as_i64().unwrap();
                        let ack = protocol::encode_json_command(&json!({
                            "opt": OPT_DOWNLOAD_FILE,
                            "optNum": opt_num,
                            "errCode": 0
                        }));
                        let _ = cmd_tx_clone.send(ack);
                        if start >= 1 {
                            let c1 = make_file_chunk_packet(opt_num, total_chunks, 1, false, &file_bytes[..512]);
                            let c2 = make_file_chunk_packet(opt_num, total_chunks, 2, true, &file_bytes[512..]);
                            // Split chunk across BLE 244B notifications to test reassembly
                            let _ = audio_tx_clone.send(c1[..244].to_vec());
                            let _ = audio_tx_clone.send(c1[244..].to_vec());
                            let _ = audio_tx_clone.send(c2);
                        }
                        continue;
                    }
                    OPT_DELETE_FILES => {
                        let targets: Vec<String> = req["list"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .filter_map(|v| v.as_str().map(str::to_string))
                            .collect();
                        files.retain(|(n, _)| !targets.contains(n));
                        json!({"opt": OPT_DELETE_FILES, "optNum": opt_num, "errCode": 0})
                    }
                    _ => json!({"opt": opt, "optNum": opt_num, "errCode": 0}),
                };
                // Fragment JSON command notifies across MTU boundaries
                let enc = protocol::encode_json_command(&resp);
                let _ = cmd_tx_clone.send(enc[..enc.len() / 2].to_vec());
                let _ = cmd_tx_clone.send(enc[enc.len() / 2..].to_vec());
            }
        });

        let session = IflytekSession::open(
            MemLink { tx: write_tx },
            "讯飞录音笔A1_11E0".to_string(),
            "test-id".to_string(),
            DEFAULT_HANDSHAKE_USER_ID.to_string(),
            cmd_rx,
            audio_rx,
        )
        .await
        .unwrap();

        let snap = session.snapshot().await.unwrap();
        assert_eq!(snap.device_id, "H00DBB0FC011E0");
        assert_eq!(snap.fw_version, "1.1.0029");
        assert_eq!(snap.battery.level, Some(70));
        assert!(!snap.battery.is_charging);
        assert!(snap.capabilities.realtime_audio);
        assert!(snap.capabilities.has_file_sync);
        assert!(!snap.capabilities.has_wifi_config);

        // Start/stop recording
        let st_on = session.start_record(None).await.unwrap();
        assert!(st_on.is_recording);
        let mut aud_rx = session.subscribe_audio();
        session.set_realtime_enabled(true).await.unwrap();
        for seq in 0..4 {
            let _ = audio_tx.send(make_realtime_packet(seq, &REAL_A1_SBC_FRAME));
        }
        let chunk = tokio::time::timeout(Duration::from_secs(2), aud_rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(chunk.sample_rate, 16_000);
        assert_eq!(chunk.channels, 1);
        assert_eq!(chunk.samples.len(), 512);
        assert!(!chunk.discontinuous);
        session.set_realtime_enabled(false).await.unwrap();

        let st_off = session.stop_record().await.unwrap();
        assert!(!st_off.is_recording);

        // Physical button event (61001)
        let mut evt_rx = session.subscribe_events();
        let _ = cmd_tx.send(protocol::encode_json_command(&json!({
            "opt": OPT_EVT_RECORD_STATE,
            "optNum": 0,
            "fileName": "2026_11_22_20_01_00.sbc",
            "status": 1
        })));
        let evt = tokio::time::timeout(Duration::from_secs(2), evt_rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(
            evt,
            SdkDeviceEvent::RecordStatus(SdkRecordStatus { is_recording: true, .. })
        ));
        // Clear simulated physical recording flag before delete_file test
        let _ = cmd_tx.send(protocol::encode_json_command(&json!({
            "opt": OPT_EVT_RECORD_STATE,
            "optNum": 0,
            "fileName": "",
            "status": 2
        })));
        let _ = evt_rx.recv().await;

        // Multi-page file list + download SBC->WAV + delete
        let list = session.list_files().await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "2026_11_22_15_47_30.sbc");
        assert!(list[0].start_at.is_some());

        let dir = std::env::temp_dir().join(format!("iflytek-sdk-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let saved = session
            .download_file(&list[0].name, dir.to_str().unwrap())
            .await
            .unwrap();
        assert!(saved.path.ends_with("2026_11_22_15_47_30.wav"));
        assert!(saved.bytes_written > 44);
        assert_eq!(saved.time_synced, Some(true));
        let wav = std::fs::read(&saved.path).unwrap();
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(wav.len(), 44 + 5 * 128 * 2);

        session.delete_file(&list[0].name).await.unwrap();
        assert!(session.list_files().await.unwrap().is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
