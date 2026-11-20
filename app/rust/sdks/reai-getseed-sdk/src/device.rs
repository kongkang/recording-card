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
    decrypt_auth_frame, encode_auth_cmd, encode_packet, format_time_sync_ascii,
    is_cloud_auth_locked_fw, parse_auth_mac_fw, parse_auth_sn, parse_file_list_csv,
    parse_mfg_data_544a, parse_mfg_fw_544a, parse_storage_free_kb, write_chunk_bytes_for_mtu,
    DecodedFrame, FrameStreamParser, PullAssembler, AUTH_CMD_MAC_FW, AUTH_CMD_SN,
    CHR_AUTH_NOTIFY_UUID, CHR_AUTH_WRITE_UUID, CHR_BATTERY_LEVEL_UUID, CHR_CTL_NOTIFY_UUID,
    CHR_CTL_WRITE_UUID, CHR_FW_REV_UUID, CMD_DELETE_FILE, CMD_FILE_LIST, CMD_PULL_FILE,
    CMD_SET_TIME, CMD_STORAGE, MFG_ID_GETSEED, NOMINAL_STORAGE_TOTAL_MB, RSP_PULL_DATA,
    RSP_PULL_END, RSP_PULL_ERR, RSP_PULL_START, SVC_AUTH_UUID, SVC_BATTERY_UUID, SVC_CTL_UUID,
    SVC_DIS_UUID,
};

const CMD_TIMEOUT: Duration = Duration::from_secs(3);
const STORAGE_PROBE_TIMEOUT: Duration = Duration::from_millis(2200);
const AUTH_PROBE_TIMEOUT: Duration = Duration::from_millis(450);
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
    auth_write: Option<Characteristic>,
    auth_notify: Option<Characteristic>,
    battery_char: Option<Characteristic>,
    fw_rev_char: Option<Characteristic>,
    frame_rx: Mutex<mpsc::UnboundedReceiver<DecodedFrame>>,
    auth_rx: Mutex<mpsc::UnboundedReceiver<[u8; 16]>>,
    io_lock: Mutex<()>,
    battery_cache: Mutex<SdkBattery>,
    fw_cache: Mutex<String>,
    serial_cache: Mutex<String>,
    mac_cache: Mutex<String>,
    ctl_locked: AtomicBool,
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

        let auth_write = chars
            .iter()
            .find(|c| c.uuid == CHR_AUTH_WRITE_UUID && c.service_uuid == SVC_AUTH_UUID)
            .or_else(|| chars.iter().find(|c| c.uuid == CHR_AUTH_WRITE_UUID))
            .cloned();

        let auth_notify = chars
            .iter()
            .find(|c| c.uuid == CHR_AUTH_NOTIFY_UUID && c.service_uuid == SVC_AUTH_UUID)
            .or_else(|| chars.iter().find(|c| c.uuid == CHR_AUTH_NOTIFY_UUID))
            .cloned();

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

        let auth_subscribed = if let Some(ref achar) = auth_notify {
            tokio::time::timeout(Duration::from_secs(2), peripheral.subscribe(achar))
                .await
                .is_ok_and(|r| r.is_ok())
        } else {
            false
        };

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
        let mut initial_mac = String::new();
        if let Ok(Ok(Some(props))) =
            tokio::time::timeout(Duration::from_millis(300), peripheral.properties()).await
        {
            if let Some(mfd) = props.manufacturer_data.get(&MFG_ID_GETSEED) {
                if let Some(mac) = parse_mfg_data_544a(mfd) {
                    initial_mac = mac;
                }
                if let Some(fw) = parse_mfg_fw_544a(mfd) {
                    fw_version = fw;
                }
            }
        }
        if fw_version.is_empty() {
            if let Some(ref fchar) = fw_rev_char {
                if let Ok(bytes) = peripheral.read(fchar).await {
                    fw_version = String::from_utf8_lossy(&bytes)
                        .trim_end_matches('\0')
                        .trim()
                        .to_string();
                }
            }
        }

        let notif_stream = peripheral
            .notifications()
            .await
            .map_err(|e| SdkError::Ble(format!("打开 Get笔记卡通知流失败: {e}")))?;

        let (events_tx, _) = broadcast::channel(64);
        let (audio_tx, _) = broadcast::channel(8);
        let (frame_tx, frame_rx) = mpsc::unbounded_channel();
        let (auth_tx, auth_rx) = mpsc::unbounded_channel();

        let device = Arc::new(Self {
            peripheral_id: peripheral.id().to_string(),
            peripheral,
            name: ble_name,
            ctl_write,
            ctl_notify,
            auth_write,
            auth_notify,
            battery_char,
            fw_rev_char,
            frame_rx: Mutex::new(frame_rx),
            auth_rx: Mutex::new(auth_rx),
            io_lock: Mutex::new(()),
            battery_cache: Mutex::new(initial_battery),
            fw_cache: Mutex::new(fw_version),
            serial_cache: Mutex::new(String::new()),
            mac_cache: Mutex::new(initial_mac),
            ctl_locked: AtomicBool::new(false),
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
                } else if notif.uuid == CHR_AUTH_NOTIFY_UUID {
                    if let Some(plain) = decrypt_auth_frame(&notif.value) {
                        let _ = auth_tx.send(plain);
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

        // 只读 0x9000 握手（MAC/FW 与序列号）：不改变鉴权状态，总预算 < 900ms
        if auth_subscribed {
            device.probe_auth_metadata_readonly().await;
        }

        // 不在 connect_peripheral 同步阻塞 0x0146 对时（v0.2.5+ 锁机后会浪费 12~40s）；
        // 仅在未明确锁定的固件上后台最佳努力同步时间。
        let fw_now = device.fw_cache.lock().await.clone();
        if !is_cloud_auth_locked_fw(&fw_now) {
            let weak_sync = Arc::downgrade(&device);
            tokio::spawn(async move {
                if let Some(dev) = weak_sync.upgrade() {
                    let _ = dev.sync_time().await;
                }
            });
        }
        Ok(device)
    }

    async fn probe_auth_metadata_readonly(&self) {
        let Some(ref awrite) = self.auth_write else {
            return;
        };
        let mut arx = self.auth_rx.lock().await;
        while arx.try_recv().is_ok() {}

        let write_type = if awrite
            .properties
            .contains(btleplug::api::CharPropFlags::WRITE_WITHOUT_RESPONSE)
        {
            WriteType::WithoutResponse
        } else {
            WriteType::WithResponse
        };

        let pkt1 = encode_auth_cmd(AUTH_CMD_MAC_FW, &[]);
        if self.peripheral.write(awrite, &pkt1, write_type).await.is_ok() {
            if let Ok(Some(plain)) = tokio::time::timeout(AUTH_PROBE_TIMEOUT, arx.recv()).await {
                if let Some((mac, fw)) = parse_auth_mac_fw(&plain) {
                    *self.mac_cache.lock().await = mac;
                    *self.fw_cache.lock().await = fw;
                }
            }
        }

        let pkt2 = encode_auth_cmd(AUTH_CMD_SN, &[]);
        if self.peripheral.write(awrite, &pkt2, write_type).await.is_ok() {
            if let Ok(Some(plain)) = tokio::time::timeout(AUTH_PROBE_TIMEOUT, arx.recv()).await {
                if let Some(sn) = parse_auth_sn(&plain) {
                    *self.serial_cache.lock().await = sn;
                }
            }
        }
    }

    pub fn classify_ctl_timeout_error(op_label: &str, cmd: u16, fw_version: &str) -> SdkError {
        if is_cloud_auth_locked_fw(fw_version) {
            let fw_label = fw_version.trim().trim_start_matches('v').trim_start_matches('V');
            SdkError::Unsupported(format!(
                "unsupported: Get笔记卡当前固件 (v{fw_label}) 已启用官方云端一机一码鉴权锁 (0x9000→0x9100)，第三方 App 仅可读取电量与设备信息，无法{op_label}（v0.1.8 及更早固件支持离线直拉）"
            ))
        } else {
            SdkError::Timeout(format!("Get笔记卡{op_label} (0x{cmd:04X}) 超时"))
        }
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
        let chunk_size = write_chunk_bytes_for_mtu(None);
        for (idx, chunk) in pkt.chunks(chunk_size).enumerate() {
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

    async fn request_cmd_with_timeout(
        &self,
        cmd: u16,
        body: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>, SdkError> {
        let _guard = self.io_lock.lock().await;
        let mut rx = self.frame_rx.lock().await;
        Self::flush_stale_frames(&mut rx).await;
        self.write_frame(cmd, body).await?;

        let deadline = tokio::time::Instant::now() + timeout;
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

    async fn request_cmd(&self, cmd: u16, body: &[u8]) -> Result<Vec<u8>, SdkError> {
        self.request_cmd_with_timeout(cmd, body, CMD_TIMEOUT).await
    }

    async fn resolved_device_id(&self) -> String {
        let sn = self.serial_cache.lock().await.clone();
        if !sn.is_empty() {
            return sn;
        }
        let mac = self.mac_cache.lock().await.clone();
        if !mac.is_empty() {
            return mac;
        }
        self.peripheral_id.clone()
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

        let storage = if self.ctl_locked.load(Ordering::SeqCst) {
            None
        } else {
            match self
                .request_cmd_with_timeout(CMD_STORAGE, &[], STORAGE_PROBE_TIMEOUT)
                .await
            {
                Ok(body) => parse_storage_free_kb(&body).map(|free_kb| {
                    let free_mb = (u64::from(free_kb) / 1024).min(NOMINAL_STORAGE_TOTAL_MB);
                    SdkStorage {
                        total_mb: NOMINAL_STORAGE_TOTAL_MB,
                        free_mb,
                        used_mb: NOMINAL_STORAGE_TOTAL_MB.saturating_sub(free_mb),
                    }
                }),
                Err(SdkError::Timeout(_)) => {
                    if is_cloud_auth_locked_fw(&fw_version) {
                        self.ctl_locked.store(true, Ordering::SeqCst);
                    }
                    None
                }
                Err(_) => None,
            }
        };

        let device_id = self.resolved_device_id().await;

        Ok(SdkSnapshot {
            capabilities: self.capabilities(),
            device_name: self.name.clone(),
            device_id,
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
        let fw = self.fw_cache.lock().await.clone();
        if self.ctl_locked.load(Ordering::SeqCst) && is_cloud_auth_locked_fw(&fw) {
            return Err(Self::classify_ctl_timeout_error("对时", CMD_SET_TIME, &fw));
        }
        let payload = format_time_sync_ascii(Local::now());
        match self.request_cmd(CMD_SET_TIME, &payload).await {
            Ok(ack) => {
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
            Err(SdkError::Timeout(_)) => {
                if is_cloud_auth_locked_fw(&fw) {
                    self.ctl_locked.store(true, Ordering::SeqCst);
                }
                Err(Self::classify_ctl_timeout_error("对时", CMD_SET_TIME, &fw))
            }
            Err(e) => Err(e),
        }
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
        let fw = self.fw_cache.lock().await.clone();
        if self.ctl_locked.load(Ordering::SeqCst) && is_cloud_auth_locked_fw(&fw) {
            return Err(Self::classify_ctl_timeout_error(
                "读取或拉取板载录音文件",
                CMD_FILE_LIST,
                &fw,
            ));
        }
        // `[1u32 LE, 5u32 LE]` 为 GetSeed 协议标准列表请求体；空载荷回包表示无文件
        let mut req = Vec::with_capacity(8);
        req.extend_from_slice(&1u32.to_le_bytes());
        req.extend_from_slice(&5u32.to_le_bytes());
        match self.request_cmd(CMD_FILE_LIST, &req).await {
            Ok(body) => Ok(parse_file_list_csv(&body)),
            Err(SdkError::Timeout(_)) => {
                if is_cloud_auth_locked_fw(&fw) {
                    self.ctl_locked.store(true, Ordering::SeqCst);
                }
                Err(Self::classify_ctl_timeout_error(
                    "读取或拉取板载录音文件",
                    CMD_FILE_LIST,
                    &fw,
                ))
            }
            Err(e) => Err(e),
        }
    }

    async fn download_file(&self, name: &str, dir: &str) -> Result<SdkSavedFile, SdkError> {
        let clean_name = name.trim();
        if clean_name.is_empty() {
            return Err(SdkError::Protocol("文件名不能为空".into()));
        }
        let fw = self.fw_cache.lock().await.clone();
        if self.ctl_locked.load(Ordering::SeqCst) && is_cloud_auth_locked_fw(&fw) {
            return Err(Self::classify_ctl_timeout_error(
                "下载板载录音文件",
                CMD_PULL_FILE,
                &fw,
            ));
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
                        if is_cloud_auth_locked_fw(&fw) {
                            self.ctl_locked.store(true, Ordering::SeqCst);
                            return Err(Self::classify_ctl_timeout_error(
                                "下载板载录音文件",
                                CMD_PULL_FILE,
                                &fw,
                            ));
                        }
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
        let fw = self.fw_cache.lock().await.clone();
        if self.ctl_locked.load(Ordering::SeqCst) && is_cloud_auth_locked_fw(&fw) {
            return Err(Self::classify_ctl_timeout_error(
                "删除板载录音文件",
                CMD_DELETE_FILE,
                &fw,
            ));
        }
        // 安全红线：仅发单文件删除 0x0044，严禁使用全盘清空指令 0x0041
        let body = match self
            .request_cmd(CMD_DELETE_FILE, clean_name.as_bytes())
            .await
        {
            Ok(b) => b,
            Err(SdkError::Timeout(_)) => {
                if is_cloud_auth_locked_fw(&fw) {
                    self.ctl_locked.store(true, Ordering::SeqCst);
                }
                return Err(Self::classify_ctl_timeout_error(
                    "删除板载录音文件",
                    CMD_DELETE_FILE,
                    &fw,
                ));
            }
            Err(e) => return Err(e),
        };
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
        if let Some(ref achar) = self.auth_notify {
            let _ = self.peripheral.unsubscribe(achar).await;
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeout_on_locked_firmware_returns_actionable_unsupported_error() {
        let locked_err = GetSeedDevice::classify_ctl_timeout_error(
            "读取或拉取板载录音文件",
            CMD_FILE_LIST,
            "0.2.7",
        );
        match locked_err {
            SdkError::Unsupported(msg) => {
                assert!(msg.starts_with("unsupported:"));
                assert!(msg.contains("0.2.7"));
                assert!(msg.contains("0x9000→0x9100"));
            }
            other => panic!("expected Unsupported, got {other:?}"),
        }

        let legacy_err = GetSeedDevice::classify_ctl_timeout_error(
            "读取或拉取板载录音文件",
            CMD_FILE_LIST,
            "0.1.8",
        );
        assert!(matches!(legacy_err, SdkError::Timeout(_)));
    }
}
