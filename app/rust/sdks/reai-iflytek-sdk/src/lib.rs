//! `reai-iflytek-sdk` —— 讯飞智能录音笔 A1 的 ReAI 风格第三方蓝牙 SDK。
//!
//! 基于实测纯 BLE ATT/GATT 协议（Actions ATS2837，`001120a0-2233-4455-6677-889912345678`）实现：
//! - 广播名 `讯飞录音笔A1_*` / Service UUID / Manufacturer Data `0x3332` 识别与 `userId` 提取
//! - 8 秒看门狗窗口内无网握手（`opt: 62012`）、本地时间同步（`opt: 62001`）与心跳保活（`opt: 62009`）
//! - 电量百分比/充电态/存储/版本快照（`opt: 62002`）与遥控开始/停止录音（`opt: 62003`）
//! - 机身物理按键录停状态主动上报（`opt: 61001`）
//! - `001120a4` 实时 SBC 推流（`01 01`）与断点分块文件拉取（`opt: 62008` / `62007` + `01 02`）
//! - 经 `reai-ext-sdk::sbc` 纯 Rust 解码为 16kHz 单声道 PCM / WAV，支持单文件删除（`opt: 62005`）

pub mod protocol;
pub mod session;

pub use protocol::SERVICE_UUID;
pub use session::IflytekSdkDriver;
