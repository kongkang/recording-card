use std::collections::HashMap;
use std::path::PathBuf;

use async_trait::async_trait;
use btleplug::platform::Peripheral;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use thiserror::Error;
use tokio::sync::broadcast;
use uuid::Uuid;

/// 统一硬件能力矩阵：所有第三方外设 SDK 必须如实声明自身能力，
/// `card_bridge` 与上层 Flutter UI 只读这些布尔/模式位进行界面裁剪与调度。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SdkCapabilities {
    pub device_kind: &'static str,
    pub display_model: &'static str,
    pub realtime_audio: bool,
    pub has_onboard_storage: bool,
    pub has_file_sync: bool,
    pub has_wifi_config: bool,
    pub has_camera_media: bool,
    pub has_physical_record_toggle: bool,
    pub has_remote_record_control: bool,
    pub has_voice_key: bool,
    pub has_mark_button: bool,
    pub has_configurable_buttons: bool,
    /// `"dual_chip"` | `"single_ota"` | `"none"`
    pub ota_mode: &'static str,
}

impl SdkCapabilities {
    /// 输出与 `card_bridge` / `card_gateway.dart` 兼容的能力位 JSON（不含外设内部私有细节）。
    pub fn to_bridge_json(self) -> Value {
        json!({
            "realtimeAudio": self.realtime_audio,
            "hasOnboardStorage": self.has_onboard_storage,
            "hasFileSync": self.has_file_sync,
            "hasWifiConfig": self.has_wifi_config,
            "hasCameraMedia": self.has_camera_media,
            "hasPhysicalRecordToggle": self.has_physical_record_toggle,
            "hasRemoteRecordControl": self.has_remote_record_control,
            "hasVoiceKey": self.has_voice_key,
            "hasMarkButton": self.has_mark_button,
            "hasConfigurableButtons": self.has_configurable_buttons,
            "otaMode": self.ota_mode,
        })
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SdkBattery {
    pub level: Option<u8>,
    pub is_charging: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SdkStorage {
    pub total_mb: u64,
    pub used_mb: u64,
    pub free_mb: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SdkRecordStatus {
    pub is_recording: bool,
    pub realtime_enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SdkSnapshot {
    pub capabilities: SdkCapabilities,
    pub device_name: String,
    pub device_id: String,
    pub fw_version: String,
    pub battery: SdkBattery,
    pub storage: Option<SdkStorage>,
    pub record: SdkRecordStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SdkFileEntry {
    pub name: String,
    pub size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seq: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub synced: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SdkSavedFile {
    pub path: PathBuf,
    pub bytes_written: u64,
    pub original_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
}

/// 统一实时音频帧：所有设备 SDK 对外只输出 16kHz / 16bit / 单声道 PCM。
#[derive(Debug, Clone)]
pub struct SdkAudioChunk {
    pub samples: Vec<i16>,
    pub sample_rate: u32,
    pub channels: u8,
    pub discontinuous: bool,
}

/// 设备侧主动推送的统一事件（与 `card_bridge` events.pull 同构）。
#[derive(Debug, Clone)]
pub enum SdkDeviceEvent {
    RecordStatus(SdkRecordStatus),
    Power(SdkBattery),
    VoiceKey { pressed: bool },
    Button { gesture: String },
    Disconnected,
}

#[derive(Debug, Error)]
pub enum SdkError {
    #[error("设备未连接或连接已断开")]
    Disconnected,
    #[error("蓝牙操作超时: {0}")]
    Timeout(String),
    #[error("协议解析失败: {0}")]
    Protocol(String),
    #[error("当前设备不支持该操作: {0}")]
    Unsupported(String),
    #[error("蓝牙传输错误: {0}")]
    Ble(String),
    #[error("文件读写失败: {0}")]
    Io(String),
}

impl From<std::io::Error> for SdkError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value.to_string())
    }
}

/// 每个第三方硬件 SDK crate 必须实现的驱动入口（用于扫描匹配 + 建连）。
#[async_trait]
pub trait RecorderSdkDriver: Send + Sync {
    fn device_kind(&self) -> &'static str;
    fn display_model(&self) -> &'static str;
    fn default_capabilities(&self) -> SdkCapabilities;

    /// 根据 BLE 广播（本地名 / 128-bit 服务 UUID / 厂商数据）判断该设备是否归属当前 SDK。
    fn matches_advertisement(
        &self,
        local_name: Option<&str>,
        services: &[Uuid],
        manufacturer_data: &HashMap<u16, Vec<u8>>,
    ) -> bool;

    /// 为未带 local_name 的纯 UUID 广播生成可读名称（例如 `Omi-A1B2`）。
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
        format!("{}-{}", self.device_kind().to_ascii_uppercase(), suffix)
    }

    async fn connect(
        &self,
        peripheral: Peripheral,
        ble_name: String,
    ) -> Result<std::sync::Arc<dyn RecorderDevice>, SdkError>;
}

/// 单个已连接硬件实例的统一 ReAI SDK 控制接口。
#[async_trait]
pub trait RecorderDevice: Send + Sync {
    fn device_name(&self) -> &str;
    fn capabilities(&self) -> SdkCapabilities;

    fn subscribe_events(&self) -> broadcast::Receiver<SdkDeviceEvent>;
    fn subscribe_audio(&self) -> broadcast::Receiver<SdkAudioChunk>;

    async fn snapshot(&self) -> Result<SdkSnapshot, SdkError>;
    async fn sync_time(&self) -> Result<Value, SdkError>;

    async fn start_record(&self, duration_secs: Option<u32>) -> Result<SdkRecordStatus, SdkError>;
    async fn stop_record(&self) -> Result<SdkRecordStatus, SdkError>;
    async fn mark(&self) -> Result<Value, SdkError> {
        Ok(json!({ "marked": true, "localOnly": true }))
    }

    async fn set_realtime_enabled(&self, enabled: bool) -> Result<(), SdkError>;

    async fn list_files(&self) -> Result<Vec<SdkFileEntry>, SdkError>;
    async fn download_file(&self, name: &str, dir: &str) -> Result<SdkSavedFile, SdkError>;
    async fn delete_file(&self, name: &str) -> Result<(), SdkError>;

    async fn disconnect(&self) -> Result<(), SdkError>;
}
