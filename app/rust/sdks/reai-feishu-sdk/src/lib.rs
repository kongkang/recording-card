//! `reai-feishu-sdk` —— soundcore Work / 飞书录音豆（D3200）的 ReAI 风格接入包。
//!
//! 本包只覆盖把板载录音取回本机所需的最小闭环：广播识别、GATT 连接、
//! 设备信息、录音列表、ECDH + AES-CTR 解密、Ogg Opus 封装，再交给
//! `reai-ext-sdk` 转成 16kHz 单声道 WAV。Wi-Fi SoftAP 快传和固件升级不在此包内。
//!
//! 线协议依据社区对 D3200（固件 04.92 一族）的实测：
//! GATT `020cf5da-…`，写 `00007777-…`，通知 `00008888-…`。

mod protocol;
mod session;

pub use protocol::SERVICE_UUID;
pub use session::FeishuSdkDriver;
