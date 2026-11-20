use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use btleplug::api::{Characteristic, Peripheral as _, WriteType};
use btleplug::platform::Peripheral;
use chrono::Local;
use futures::StreamExt;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, Mutex};
use tokio::task::JoinHandle;
use uuid::Uuid;

use reai_ext_sdk::{
    RecorderDevice, RecorderSdkDriver, SdkAudioChunk, SdkBattery, SdkCapabilities, SdkDeviceEvent,
    SdkError, SdkFileEntry, SdkRecordStatus, SdkSavedFile, SdkSnapshot, SdkStorage,
};

use crate::protocol::{
    encode_packet, format_time_sync_ascii, parse_file_list_csv, parse_storage_free_kb,
    DecodedFrame, FrameStreamParser, PullAssembler, CHR_BATTERY_LEVEL_UUID, CHR_CTL_NOTIFY_UUID,
    CHR_CTL_WRITE_UUID, CHR_FW_REV_UUID, CMD_DELETE_FILE, CMD_FILE_LIST, CMD_PULL_FILE,
    CMD_SET_TIME, CMD_STATUS, CMD_STORAGE, MFG_ID_GETSEED, NOMINAL_STORAGE_TOTAL_MB, RSP_PULL_DATA,
    RSP_PULL_END, RSP_PULL_ERR, RSP_PULL_START, SVC_BATTERY_UUID, SVC_CTL_UUID, SVC_DIS_UUID,
    WRITE_CHUNK_BYTES,
};

const CMD_TIMEOUT: Duration = Duration::from_secs(12);
const PULL_IDLE_TIMEOUT: Duration = Duration::from_secs(20);

pub struct GetSeedSdkDriver;

impl GetSeedSdkDriver {
    pub fn capabilities() -> SdkCapabilities {
        SdkCapabilities {
            device_kind: "getseed_gsc10",
            display_model: "Get笔记卡",
            realtime_audio: false,
            has_onboard_storage: true,
            has_file_sync: true,
            has_wifi_config: false,
            has_camera_media: false,
            has_physical_record_toggle: true,
            has_remote_record_control: false,
            has_voice_key: false,
            has_mark_button: false,
            has_configurable_buttons: false,
            ota_mode: "none",
        }
    }
}

#[async_trait]
impl RecorderSdkDriver for GetSeedSdkDriver {
    fn device_kind(&self) -> &'static str {
        "getseed_gsc10"
    }

    fn display_model(&self) -> &'static str {
        "Get笔记卡"
    }

    fn default_capabilities(&self) -> SdkCapabilities {
        Self::capabilities()
    }

    fn matches_advertisement(
        &self,
        local_name: Option<&str>,
        _services: &[Uuid],
        manufacturer_data: &HashMap<u16, Vec<u8>>,
    ) -> bool {
        if manufacturer_data.contains_key(&MFG_ID_GETSEED) {
            return true;
        }
        if let Some(name) = local_name {
            let t = name.trim();
            // 广播名可能是任意 UTF-8（真机实测遇到中文前缀名「讯飞录音笔…」），
            // 字节切片会 panic 在非字符边界；get(..4) 越界/断点返回 None。
            return t
                .get(..4)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case("Get-"));
        }
        false
    }

    fn fallback_ble_name(&self, peripheral_id: &str) -> String {
        let compact: String = peripheral_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .rev()
            .take(6)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let suffix = if compact.is_empty() {
            "GSC10".to_string()
        } else {
            compact.to_ascii_uppercase()
        };
        format!("Get-{suffix}")
    }

    async fn connect(
        &self,
        peripheral: Peripheral,
        ble_name: String,
    ) -> Result<Arc<dyn RecorderDevice>, SdkError> {
        let dev = GetSeedDevice::connect_peripheral(peripheral, ble_name).await?;
        Ok(dev)
    }
}

pub struct GetSeedDevice {
    peripheral: Peripheral,
    name: String,
    peripheral_id: String,
    ctl_write: Characteristic,
    ctl_notify: Characteristic,
    battery_char: Option<Characteristic>,
    fw_rev_char: Option<Characteristic>,
    frame_rx: Mutex<mpsc::UnboundedReceiver<DecodedFrame>>,
    io_lock: Mutex<()>,
    battery_cache: Mutex<SdkBattery>,
    fw_cache: Mutex<String>,
    events_tx: broadcast::Sender<SdkDeviceEvent>,
    audio_tx: broadcast::Sender<SdkAudioChunk>,
    connected: AtomicBool,
    pump_task: Mutex<Option<JoinHandle<()>>>,
}

impl GetSeedDevice {
    async fn connect_peripheral(
        peripheral: Peripheral,
        ble_name: String,
    ) -> Result<Arc<Self>, SdkError> {
        if !peripheral
            .is_connected()
            .await
            .map_err(|e| SdkError::Ble(e.to_string()))?
        {
            tokio::time::timeout(Duration::from_secs(18), peripheral.connect())
                .await
                .map_err(|_| SdkError::Timeout("Get笔记卡蓝牙建连超时".into()))?
                .map_err(|e| SdkError::Ble(format!("Get笔记卡连接失败: {e}")))?;
        }

        tokio::time::timeout(Duration::from_secs(15), peripheral.discover_services())
            .await
            .map_err(|_| SdkError::Timeout("发现 Get笔记卡服务超时".into()))?
            .map_err(|e| SdkError::Ble(format!("发现 Get笔记卡服务失败: {e}")))?;

        let chars = peripheral.characteristics();
        let ctl_write = chars
            .iter()
            .find(|c| c.uuid == CHR_CTL_WRITE_UUID && c.service_uuid == SVC_CTL_UUID)
            .or_else(|| chars.iter().find(|c| c.uuid == CHR_CTL_WRITE_UUID))
            .cloned()
            .ok_or_else(|| SdkError::Protocol("未找到 Get笔记卡控制写特征 0x9101".into()))?;

        let ctl_notify = chars
            .iter()
            .find(|c| c.uuid == CHR_CTL_NOTIFY_UUID && c.service_uuid == SVC_CTL_UUID)
            .or_else(|| chars.iter().find(|c| c.uuid == CHR_CTL_NOTIFY_UUID))
            .cloned()
            .ok_or_else(|| SdkError::Protocol("未找到 Get笔记卡通知特征 0x9102".into()))?;

        let battery_char = chars
            .iter()
            .find(|c| c.uuid == CHR_BATTERY_LEVEL_UUID && c.service_uuid == SVC_BATTERY_UUID)
            .or_else(|| chars.iter().find(|c| c.uuid == CHR_BATTERY_LEVEL_UUID))
            .cloned();

        let fw_rev_char = chars
            .iter()
            .find(|c| c.uuid == CHR_FW_REV_UUID && c.service_uuid == SVC_DIS_UUID)
            .or_else(|| chars.iter().find(|c| c.uuid == CHR_FW_REV_UUID))
            .cloned();

        peripheral
            .subscribe(&ctl_notify)
            .await
            .map_err(|e| SdkError::Ble(format!("订阅 Get笔记卡控制通道失败: {e}")))?;

        let mut initial_battery = SdkBattery::default();
        if let Some(ref bchar) = battery_char {
            if let Ok(bytes) = peripheral.read(bchar).await {
                if let Some(&lvl) = bytes.first() {
                    initial_battery.level = Some(lvl.min(100));
                }
            }
            let _ = peripheral.subscribe(bchar).await;
        }

        let mut fw_version = String::new();
        if let Some(ref fchar) = fw_rev_char {
            if let Ok(bytes) = peripheral.read(fchar).await {
                fw_version = String::from_utf8_lossy(&bytes)
                    .trim_end_matches('\0')
                    .trim()
                    .to_string();
            }
        }

        let notif_stream = peripheral
            .notifications()
            .await
            .map_err(|e| SdkError::Ble(format!("打开 Get笔记卡通知流失败: {e}")))?;

        let (events_tx, _) = broadcast::channel(64);
        let (audio_tx, _) = broadcast::channel(8);
        let (frame_tx, frame_rx) = mpsc::unbounded_channel();

        let device = Arc::new(Self {
            peripheral_id: peripheral.id().to_string(),
            peripheral,
            name: ble_name,
            ctl_write,
            ctl_notify,
            battery_char,
            fw_rev_char,
            frame_rx: Mutex::new(frame_rx),
            io_lock: Mutex::new(()),
            battery_cache: Mutex::new(initial_battery),
            fw_cache: Mutex::new(fw_version),
            events_tx,
            audio_tx,
            connected: AtomicBool::new(true),
            pump_task: Mutex::new(None),
        });

        let weak = Arc::downgrade(&device);
        let task = tokio::spawn(async move {
            let mut stream = notif_stream;
            let mut parser = FrameStreamParser::default();
            while let Some(notif) = stream.next().await {
                let Some(dev) = weak.upgrade() else {
                    break;
                };
                if notif.uuid == CHR_CTL_NOTIFY_UUID {
                    for frame in parser.push(&notif.value) {
                        let _ = frame_tx.send(frame);
                    }
                } else if notif.uuid == CHR_BATTERY_LEVEL_UUID {
                    if let Some(&lvl) = notif.value.first() {
                        let lvl = lvl.min(100);
                        let updated = {
                            let mut guard = dev.battery_cache.lock().await;
                            guard.level = Some(lvl);
                            guard.clone()
                        };
                        let _ = dev.events_tx.send(SdkDeviceEvent::Power(updated));
                    }
                }
            }
            if let Some(dev) = weak.upgrade() {
                dev.connected.store(false, Ordering::SeqCst);
                let _ = dev.events_tx.send(SdkDeviceEvent::Disconnected);
            }
        });
        *device.pump_task.lock().await = Some(task);

        // 对时：保证新录制的 .ogg 文件名与创建时间准确
        let _ = device.sync_time().await;
        Ok(device)
    }

    async fn write_frame(&self, cmd: u16, body: &[u8]) -> Result<(), SdkError> {
        if !self.connected.load(Ordering::SeqCst) {
            return Err(SdkError::Disconnected);
        }
        let pkt = encode_packet(cmd, body)?;
        let write_type = if self
            .ctl_write
            .properties
            .contains(btleplug::api::CharPropFlags::WRITE_WITHOUT_RESPONSE)
        {
            WriteType::WithoutResponse
        } else {
            WriteType::WithResponse
        };
        for (idx, chunk) in pkt.chunks(WRITE_CHUNK_BYTES).enumerate() {
            if idx > 0 {
                tokio::time::sleep(Duration::from_millis(4)).await;
            }
            self.peripheral
                .write(&self.ctl_write, chunk, write_type)
                .await
                .map_err(|e| SdkError::Ble(format!("Get笔记卡写入失败: {e}")))?;
        }
        Ok(())
    }

    async fn flush_stale_frames(rx: &mut mpsc::UnboundedReceiver<DecodedFrame>) {
        while rx.try_recv().is_ok() {}
    }

    async fn request_cmd(&self, cmd: u16, body: &[u8]) -> Result<Vec<u8>, SdkError> {
        let _guard = self.io_lock.lock().await;
        let mut rx = self.frame_rx.lock().await;
        Self::flush_stale_frames(&mut rx).await;
        self.write_frame(cmd, body).await?;

        let deadline = tokio::time::Instant::now() + CMD_TIMEOUT;
        loop {
            let rem = deadline.saturating_duration_since(tokio::time::Instant::now());
            if rem.is_zero() {
                return Err(SdkError::Timeout(format!(
                    "Get笔记卡指令 0x{cmd:04X} 超时"
                )));
            }
            match tokio::time::timeout(rem, rx.recv()).await {
                Ok(Some(frame)) if frame.cmd == cmd => return Ok(frame.body),
                Ok(Some(_)) => continue,
                Ok(None) => return Err(SdkError::Disconnected),
                Err(_) => {
                    return Err(SdkError::Timeout(format!(
                        "Get笔记卡指令 0x{cmd:04X} 超时"
                    )));
                }
            }
        }
    }

    async fn read_battery_now(&self) -> SdkBattery {
        if let Some(ref bchar) = self.battery_char {
            if let Ok(Ok(bytes)) =
                tokio::time::timeout(Duration::from_secs(3), self.peripheral.read(bchar)).await
            {
                if let Some(&lvl) = bytes.first() {
                    let mut guard = self.battery_cache.lock().await;
                    guard.level = Some(lvl.min(100));
                    return guard.clone();
                }
            }
        }
        self.battery_cache.lock().await.clone()
    }
}

#[async_trait]
impl RecorderDevice for GetSeedDevice {
    fn device_name(&self) -> &str {
        &self.name
    }

    fn capabilities(&self) -> SdkCapabilities {
        GetSeedSdkDriver::capabilities()
    }

    fn subscribe_events(&self) -> broadcast::Receiver<SdkDeviceEvent> {
        self.events_tx.subscribe()
    }

    fn subscribe_audio(&self) -> broadcast::Receiver<SdkAudioChunk> {
        self.audio_tx.subscribe()
    }

    async fn snapshot(&self) -> Result<SdkSnapshot, SdkError> {
        let is_conn = self
            .peripheral
            .is_connected()
            .await
            .map_err(|e| SdkError::Ble(e.to_string()))?;
        if !is_conn {
            self.connected.store(false, Ordering::SeqCst);
            return Err(SdkError::Disconnected);
        }

        let battery = self.read_battery_now().await;
        let storage = match self.request_cmd(CMD_STORAGE, &[]).await {
            Ok(body) => parse_storage_free_kb(&body).map(|free_kb| {
                let free_mb = (u64::from(free_kb) / 1024).min(NOMINAL_STORAGE_TOTAL_MB);
                SdkStorage {
                    total_mb: NOMINAL_STORAGE_TOTAL_MB,
                    free_mb,
                    used_mb: NOMINAL_STORAGE_TOTAL_MB.saturating_sub(free_mb),
                }
            }),
            Err(_) => None,
        };
        // Best-effort status ping to keep link telemetry alive
        let _ = self.request_cmd(CMD_STATUS, &[]).await;

        let mut fw_version = self.fw_cache.lock().await.clone();
        if fw_version.is_empty() {
            if let Some(ref fchar) = self.fw_rev_char {
                if let Ok(Ok(bytes)) =
                    tokio::time::timeout(Duration::from_secs(2), self.peripheral.read(fchar)).await
                {
                    let parsed = String::from_utf8_lossy(&bytes)
                        .trim_end_matches('\0')
                        .trim()
                        .to_string();
                    if !parsed.is_empty() {
                        *self.fw_cache.lock().await = parsed.clone();
                        fw_version = parsed;
                    }
                }
            }
        }

        Ok(SdkSnapshot {
            capabilities: self.capabilities(),
            device_name: self.name.clone(),
            device_id: self.peripheral_id.clone(),
            fw_version,
            battery,
            storage,
            record: SdkRecordStatus {
                is_recording: false,
                realtime_enabled: false,
                session: None,
                error: None,
                reason: Some("physical_only".into()),
            },
        })
    }

    async fn sync_time(&self) -> Result<Value, SdkError> {
        let payload = format_time_sync_ascii(Local::now());
        let ack = self.request_cmd(CMD_SET_TIME, &payload).await?;
        let epoch = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Ok(json!({
            "synced": true,
            "epoch": epoch,
            "ack": ack.first().copied(),
        }))
    }

    async fn start_record(&self, _duration_secs: Option<u32>) -> Result<SdkRecordStatus, SdkError> {
        Err(SdkError::Unsupported(
            "Get笔记卡暂不支持从 App 遥控起录，请短按机身按键开始/结束录音，录完点「同步」拉取"
                .into(),
        ))
    }

    async fn stop_record(&self) -> Result<SdkRecordStatus, SdkError> {
        Err(SdkError::Unsupported(
            "Get笔记卡请直接通过机身按键停止录音，然后点「同步」拉取"
                .into(),
        ))
    }

    async fn set_realtime_enabled(&self, _enabled: bool) -> Result<(), SdkError> {
        Err(SdkError::Unsupported(
            "Get笔记卡为离线存储文件传输架构，不支持实时音频流"
                .into(),
        ))
    }

    async fn list_files(&self) -> Result<Vec<SdkFileEntry>, SdkError> {
        // `[1u32 LE, 5u32 LE]` 为 GetSeed 协议标准列表请求体；空载荷回包表示无文件
        let mut req = Vec::with_capacity(8);
        req.extend_from_slice(&1u32.to_le_bytes());
        req.extend_from_slice(&5u32.to_le_bytes());
        match self.request_cmd(CMD_FILE_LIST, &req).await {
            Ok(body) => Ok(parse_file_list_csv(&body)),
            Err(SdkError::Timeout(_)) => Ok(Vec::new()),
            Err(e) => Err(e),
        }
    }

    async fn download_file(&self, name: &str, dir: &str) -> Result<SdkSavedFile, SdkError> {
        let clean_name = name.trim();
        if clean_name.is_empty() {
            return Err(SdkError::Protocol("文件名不能为空".into()));
        }
        let mut req = Vec::with_capacity(4 + clean_name.len());
        req.extend_from_slice(&0u32.to_le_bytes());
        req.extend_from_slice(clean_name.as_bytes());

        let bytes = {
            let _guard = self.io_lock.lock().await;
            let mut rx = self.frame_rx.lock().await;
            Self::flush_stale_frames(&mut rx).await;
            self.write_frame(CMD_PULL_FILE, &req).await?;

            let mut asm = PullAssembler::default();
            loop {
                match tokio::time::timeout(PULL_IDLE_TIMEOUT, rx.recv()).await {
                    Ok(Some(frame)) => match frame.cmd {
                        RSP_PULL_START | RSP_PULL_DATA | RSP_PULL_END | RSP_PULL_ERR => {
                            if asm.handle_frame(frame.cmd, &frame.body)? {
                                break;
                            }
                        }
                        _ => continue,
                    },
                    Ok(None) => return Err(SdkError::Disconnected),
                    Err(_) => {
                        return Err(SdkError::Timeout(format!(
                            "拉取 Get笔记卡录音文件 {clean_name} 超时"
                        )));
                    }
                }
            }
            asm.take_bytes()
        };

        let out_dir = PathBuf::from(dir);
        tokio::fs::create_dir_all(&out_dir).await?;
        let base_name = clean_name
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or("recording.ogg");
        let dest = out_dir.join(base_name);
        tokio::fs::write(&dest, &bytes).await?;

        Ok(SdkSavedFile {
            path: dest,
            bytes_written: bytes.len() as u64,
            original_name: clean_name.to_string(),
            device_name: Some(self.name.clone()),
        })
    }

    async fn delete_file(&self, name: &str) -> Result<(), SdkError> {
        let clean_name = name.trim();
        if clean_name.is_empty() {
            return Err(SdkError::Protocol("删除文件名不能为空".into()));
        }
        // 安全红线：仅发单文件删除 0x0044，严禁使用全盘清空指令 0x0041
        let body = self
            .request_cmd(CMD_DELETE_FILE, clean_name.as_bytes())
            .await?;
        if body.first().copied() == Some(0x01) {
            Ok(())
        } else {
            Err(SdkError::Protocol(format!(
                "Get笔记卡删除文件 {clean_name} 返回异常应答: {body:?}"
            )))
        }
    }

    async fn disconnect(&self) -> Result<(), SdkError> {
        self.connected.store(false, Ordering::SeqCst);
        if let Some(handle) = self.pump_task.lock().await.take() {
            handle.abort();
        }
        let _ = self.peripheral.unsubscribe(&self.ctl_notify).await;
        if let Some(ref bchar) = self.battery_char {
            let _ = self.peripheral.unsubscribe(bchar).await;
        }
        self.peripheral
            .disconnect()
            .await
            .map_err(|e| SdkError::Ble(e.to_string()))?;
        Ok(())
    }
}
