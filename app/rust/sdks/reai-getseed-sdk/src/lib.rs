//! `reai-getseed-sdk` —— 得到 Get 笔记录音卡（GetSeed GSC10）ReAI 风格独立 SDK 封装。

pub mod device;
pub mod protocol;

pub use device::{GetSeedDevice, GetSeedSdkDriver};
