//! `reai-ext-sdk` —— 第三方蓝牙录音硬件统一 ReAI SDK 协议层。
//!
//! 每款第三方硬件单独实现一个 `reai-*-sdk` crate，向本 trait 适配：
//! - 设备发现与能力位声明（`SdkCapabilities`）
//! - 16kHz / 16bit / 单声道 PCM 实时流（`SdkAudioChunk`）
//! - 离线录音文件同步、转换（Ogg Opus / LC3 / μ-law / PCM -> 16kHz WAV）与删除

pub mod audio;
pub mod types;

pub use types::{
    RecorderDevice, RecorderSdkDriver, SdkAudioChunk, SdkBattery, SdkCapabilities, SdkDeviceEvent,
    SdkError, SdkFileEntry, SdkRecordStatus, SdkSavedFile, SdkSavedFilePart, SdkSnapshot,
    SdkStorage,
};
