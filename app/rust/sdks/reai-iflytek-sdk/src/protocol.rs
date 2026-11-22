//! 讯飞智能录音笔 A1 BLE 控制面 JSON 与高速音视频二进制帧协议。

use std::collections::HashMap;

use chrono::{Datelike, Local, NaiveDateTime, TimeZone, Timelike};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub const SERVICE_UUID: Uuid = Uuid::from_u128(0x001120a0_2233_4455_6677_889912345678);
pub const CHAR_CMD_WRITE_UNRESP_UUID: Uuid =
    Uuid::from_u128(0x001120a1_2233_4455_6677_889912345678);
pub const CHAR_CMD_WRITE_UUID: Uuid = Uuid::from_u128(0x001120a2_2233_4455_6677_889912345678);
pub const CHAR_CMD_NOTIFY_UUID: Uuid = Uuid::from_u128(0x001120a3_2233_4455_6677_889912345678);
pub const CHAR_AUDIO_NOTIFY_UUID: Uuid = Uuid::from_u128(0x001120a4_2233_4455_6677_889912345678);

/// 讯飞 A1 广播 Manufacturer Data 公司 ID（LE `[0x32, 0x33]` = `"23"` + 14 字节后缀 = 16 位 userId）。
pub const MFD_COMPANY_ID: u16 = 0x3332;
pub const DEFAULT_HANDSHAKE_USER_ID: &str = "2303051401437265";

pub const OPT_SYNC_TIME: u32 = 62001;
pub const OPT_DEVICE_INFO: u32 = 62002;
pub const OPT_RECORD_CTRL: u32 = 62003;
pub const OPT_FILE_LIST: u32 = 62004;
pub const OPT_DELETE_FILES: u32 = 62005;
pub const OPT_DOWNLOAD_FILE: u32 = 62007;
pub const OPT_FILE_SIZE: u32 = 62008;
pub const OPT_HEARTBEAT: u32 = 62009;
pub const OPT_HANDSHAKE: u32 = 62012;

pub const OPT_EVT_RECORD_STATE: u32 = 61001;
pub const OPT_EVT_AUTH_TIMEOUT: u32 = 61009;

pub const RECORD_CTRL_PAUSE: i32 = 0;
pub const RECORD_CTRL_START: i32 = 1;
pub const RECORD_CTRL_STOP: i32 = 2;
pub const RECORD_CTRL_RESUME: i32 = 3;

pub const UPLOAD_CHUNK_SIZE: usize = 512;
pub const BINARY_FRAME_MAGIC: [u8; 4] = [0x00, 0x55, 0xFF, 0xAA];

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct A1DeviceInfo {
    #[serde(default)]
    pub disk_free: u64,
    #[serde(default)]
    pub disk_total: u64,
    #[serde(default)]
    pub disk_rec_time: u64,
    #[serde(default)]
    pub disk_sta: i32,
    #[serde(default)]
    pub rec_sta: i32,
    #[serde(default)]
    pub rtt_sta: i32,
    #[serde(default)]
    pub bat_level: u8,
    #[serde(default)]
    pub charging_sta: i32,
    #[serde(default)]
    pub ble_name: String,
    #[serde(default)]
    pub rec_file_name: String,
    #[serde(default)]
    pub fw_version: String,
    #[serde(default)]
    pub ota_version: String,
    #[serde(default)]
    pub sn: String,
    #[serde(default)]
    pub blue_addr: String,
    #[serde(default)]
    pub power_off_time: i32,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct A1FileItem {
    pub file_name: String,
    #[serde(default)]
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AudioPacket {
    RealtimeSbc {
        seq: u32,
        sbc_frame: Vec<u8>,
    },
    FileChunk {
        opt_num: u32,
        total_chunks: u32,
        chunk_id: u32,
        is_last: bool,
        data: Vec<u8>,
    },
}

pub fn extract_user_id_from_mfd(manufacturer_data: &HashMap<u16, Vec<u8>>) -> Option<String> {
    let payload = manufacturer_data.get(&MFD_COMPANY_ID)?;
    let mut raw = Vec::with_capacity(2 + payload.len());
    raw.extend_from_slice(&MFD_COMPANY_ID.to_le_bytes());
    raw.extend_from_slice(payload);
    while raw.last() == Some(&0) {
        raw.pop();
    }
    if raw.len() < 8 || !raw.iter().all(|b| b.is_ascii_alphanumeric()) {
        return None;
    }
    String::from_utf8(raw).ok()
}

pub fn matches_a1_advertisement(
    local_name: Option<&str>,
    services: &[Uuid],
    manufacturer_data: &HashMap<u16, Vec<u8>>,
) -> bool {
    if services.iter().any(|u| *u == SERVICE_UUID) {
        return true;
    }
    if extract_user_id_from_mfd(manufacturer_data).is_some() {
        return true;
    }
    let Some(name) = local_name.map(str::trim).filter(|s| !s.is_empty()) else {
        return false;
    };
    let lower = name.to_lowercase();
    name.starts_with("讯飞录音笔A1")
        || lower.starts_with("讯飞录音笔a1")
        || name.starts_with("訊飛錄音筆A1")
        || lower.starts_with("iflytek_a1")
        || lower.starts_with("iflytek a1")
        || lower.starts_with("iflyrec_a1")
}

pub fn encode_json_command(value: &Value) -> Vec<u8> {
    let mut bytes = serde_json::to_vec(value).unwrap_or_default();
    bytes.push(0);
    bytes
}

pub fn build_sync_time_command(opt_num: u32) -> Vec<u8> {
    let now = Local::now();
    encode_json_command(&json!({
        "opt": OPT_SYNC_TIME,
        "optNum": opt_num,
        "year": now.year(),
        "mon": now.month(),
        "day": now.day(),
        "hour": now.hour(),
        "min": now.minute(),
        "sec": now.second(),
    }))
}

pub fn build_handshake_command(opt_num: u32, user_id: &str) -> Vec<u8> {
    encode_json_command(&json!({
        "opt": OPT_HANDSHAKE,
        "audType": 0,
        "optNum": opt_num,
        "userId": user_id,
    }))
}

/// 将 A1 文件名（`YYYY_MM_DD_HH_MM_SS.sbc` / `.wav`）按本机时区解析为 Unix 秒。
pub fn parse_a1_filename_epoch_sec(name: &str) -> Option<i64> {
    let base = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(name)
        .trim();
    let stem = base
        .strip_suffix(".sbc")
        .or_else(|| base.strip_suffix(".SBC"))
        .or_else(|| base.strip_suffix(".wav"))
        .or_else(|| base.strip_suffix(".WAV"))
        .unwrap_or(base);
    let naive = NaiveDateTime::parse_from_str(stem, "%Y_%m_%d_%H_%M_%S").ok()?;
    let dt = Local.from_local_datetime(&naive).earliest()?;
    let ts = dt.timestamp();
    (1_577_836_800..=4_102_444_800).contains(&ts).then_some(ts)
}

/// CRC-8/ATM (`poly = 0x07, init = 0x00, xorout = 0x00`)，用于 `001120a4` 二进制包校验。
pub fn crc8_atm(data: &[u8]) -> u8 {
    let mut crc = 0u8;
    for &byte in data {
        crc ^= byte;
        for _ in 0..8 {
            crc = if (crc & 0x80) != 0 {
                (crc << 1) ^ 0x07
            } else {
                crc << 1
            };
        }
    }
    crc
}

/// `001120a3` 控制面通知 `\0` 结尾 JSON 分包重组器。
pub struct JsonNotifyAssembler {
    buf: Vec<u8>,
}

impl Default for JsonNotifyAssembler {
    fn default() -> Self {
        Self::new()
    }
}

impl JsonNotifyAssembler {
    pub fn new() -> Self {
        Self {
            buf: Vec::with_capacity(2048),
        }
    }

    pub fn feed(&mut self, chunk: &[u8]) -> Vec<Value> {
        self.buf.extend_from_slice(chunk);
        let mut out = Vec::new();
        while let Some(nul) = self.buf.iter().position(|&b| b == 0) {
            let msg: Vec<u8> = self.buf.drain(..=nul).collect();
            let raw = &msg[..msg.len() - 1];
            let trimmed = String::from_utf8_lossy(raw);
            let s = trimmed.trim();
            if s.is_empty() {
                continue;
            }
            if let Ok(val) = serde_json::from_str::<Value>(s) {
                out.push(val);
            }
        }
        out
    }
}

/// `001120a4` 二进制音频/文件分包重组与 CRC-8 校验器。
pub struct BinaryFrameAssembler {
    buf: Vec<u8>,
}

impl Default for BinaryFrameAssembler {
    fn default() -> Self {
        Self::new()
    }
}

impl BinaryFrameAssembler {
    pub fn new() -> Self {
        Self {
            buf: Vec::with_capacity(8192),
        }
    }

    pub fn clear(&mut self) {
        self.buf.clear();
    }

    pub fn feed(&mut self, chunk: &[u8]) -> Vec<AudioPacket> {
        self.buf.extend_from_slice(chunk);
        let mut out = Vec::new();

        loop {
            let Some(magic_pos) = self
                .buf
                .windows(BINARY_FRAME_MAGIC.len())
                .position(|w| w == BINARY_FRAME_MAGIC)
            else {
                // 保留最后最多 3 字节以便跨包匹配魔数前缀
                if self.buf.len() > 3 {
                    let drop_n = self.buf.len() - 3;
                    self.buf.drain(..drop_n);
                }
                break;
            };
            if magic_pos > 0 {
                self.buf.drain(..magic_pos);
            }
            if self.buf.len() < 16 {
                break;
            }
            let body_len = usize::from(u16::from_le_bytes([self.buf[10], self.buf[11]]));
            let total_len = 14usize.saturating_add(body_len);
            if !(17..=4096).contains(&total_len) {
                // 假魔数碰撞，跳过 1 字节重同步
                self.buf.drain(..1);
                continue;
            }
            if self.buf.len() < total_len {
                break;
            }
            let expected_crc = self.buf[total_len - 1];
            let actual_crc = crc8_atm(&self.buf[..total_len - 1]);
            if actual_crc != expected_crc {
                log::debug!(
                    "[iflytek-a1] 010x CRC-8 不匹配: got=0x{actual_crc:02x}, want=0x{expected_crc:02x}"
                );
                self.buf.drain(..1);
                continue;
            }

            let frame: Vec<u8> = self.buf.drain(..total_len).collect();
            let subtype = [frame[14], frame[15]];
            match subtype {
                [0x01, 0x01] if total_len >= 21 => {
                    let seq = u32::from_le_bytes([frame[16], frame[17], frame[18], frame[19]]);
                    let sbc_frame = frame[20..total_len - 1].to_vec();
                    out.push(AudioPacket::RealtimeSbc { seq, sbc_frame });
                }
                [0x01, 0x02] if total_len >= 30 => {
                    let opt_num = u32::from_le_bytes([frame[16], frame[17], frame[18], frame[19]]);
                    let total_chunks =
                        u32::from_le_bytes([frame[20], frame[21], frame[22], frame[23]]);
                    let chunk_id = u32::from_le_bytes([frame[24], frame[25], frame[26], frame[27]]);
                    let flag = frame[28];
                    let data = frame[29..total_len - 1].to_vec();
                    out.push(AudioPacket::FileChunk {
                        opt_num,
                        total_chunks,
                        chunk_id,
                        is_last: flag == 0x01,
                        data,
                    });
                }
                _ => {}
            }
        }

        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_user_id_from_0x3332_mfd_and_matches_advertisement() {
        let mut mfd = HashMap::new();
        mfd.insert(MFD_COMPANY_ID, b"03051401437265".to_vec());
        assert_eq!(
            extract_user_id_from_mfd(&mfd).as_deref(),
            Some("2303051401437265")
        );
        assert!(matches_a1_advertisement(Some("讯飞录音笔A1_11E0"), &[], &HashMap::new()));
        assert!(matches_a1_advertisement(None, &[SERVICE_UUID], &HashMap::new()));
        assert!(matches_a1_advertisement(None, &[], &mfd));
        assert!(!matches_a1_advertisement(Some("DYJ_1234"), &[], &HashMap::new()));
    }

    #[test]
    fn reassembles_fragmented_json_and_binary_audio_frames() {
        let mut json_asm = JsonNotifyAssembler::new();
        assert!(json_asm.feed(br#"{"opt":62002,"batLevel""#).is_empty());
        let msgs = json_asm.feed(b":70,\"errCode\":0}\0{\"opt\":61001,\"status\":1}\0");
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0]["batLevel"], 70);
        assert_eq!(msgs[1]["opt"], 61001);

        // Build a synthetic 01 01 realtime SBC packet
        let mut rt = vec![0x00, 0x55, 0xFF, 0xAA, 0, 0, 0, 0, 0x01, 0x04];
        rt.extend_from_slice(&135u16.to_le_bytes()); // total_len = 14 + 135 = 149
        rt.extend_from_slice(&[0x00, 0x00, 0x01, 0x01]);
        rt.extend_from_slice(&42u32.to_le_bytes());
        rt.extend_from_slice(&vec![0x9C; 128]);
        let crc = crc8_atm(&rt);
        rt.push(crc);

        // Build a 01 02 file chunk split across 2 notifies
        let mut fc = vec![0x00, 0x55, 0xFF, 0xAA, 0, 0, 0, 0, 0x01, 0x04];
        fc.extend_from_slice(&528u16.to_le_bytes());
        fc.extend_from_slice(&[0x00, 0x00, 0x01, 0x02]);
        fc.extend_from_slice(&7u32.to_le_bytes());
        fc.extend_from_slice(&10u32.to_le_bytes());
        fc.extend_from_slice(&3u32.to_le_bytes());
        fc.push(0x02);
        fc.extend_from_slice(&vec![0xAB; 512]);
        let fc_crc = crc8_atm(&fc);
        fc.push(fc_crc);

        let mut bin_asm = BinaryFrameAssembler::new();
        let mut pkts = bin_asm.feed(&rt[..80]);
        assert!(pkts.is_empty());
        let mut second = rt[80..].to_vec();
        second.extend_from_slice(&fc[..244]);
        pkts = bin_asm.feed(&second);
        assert_eq!(
            pkts,
            vec![AudioPacket::RealtimeSbc {
                seq: 42,
                sbc_frame: vec![0x9C; 128],
            }]
        );
        let pkts2 = bin_asm.feed(&fc[244..]);
        assert_eq!(
            pkts2,
            vec![AudioPacket::FileChunk {
                opt_num: 7,
                total_chunks: 10,
                chunk_id: 3,
                is_last: false,
                data: vec![0xAB; 512],
            }]
        );
    }

    #[test]
    fn parses_local_a1_filename_timestamps() {
        let ts = parse_a1_filename_epoch_sec("2026_11_22_15_47_30.sbc").expect("valid timestamp");
        assert!(ts > 1_700_000_000);
        assert_eq!(parse_a1_filename_epoch_sec("invalid.sbc"), None);
    }
}
