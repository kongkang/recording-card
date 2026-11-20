use aes::cipher::{generic_array::GenericArray, BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes128;
use chrono::{DateTime, Local, NaiveDateTime, TimeZone};
use reai_ext_sdk::{SdkError, SdkFileEntry};
use uuid::Uuid;

pub const MFG_ID_GETSEED: u16 = 0x544A;

pub const SVC_AUTH_UUID: Uuid = Uuid::from_u128(0x00009000_0000_1000_8000_57616c6b697a);
pub const CHR_AUTH_WRITE_UUID: Uuid = Uuid::from_u128(0x00009001_0000_1000_8000_57616c6b697a);
pub const CHR_AUTH_NOTIFY_UUID: Uuid = Uuid::from_u128(0x00009002_0000_1000_8000_57616c6b697a);
pub const AUTH_AES_KEY: [u8; 16] = *b"Walkiz52832iLock";
pub const AUTH_CMD_MAC_FW: u8 = 0x01;
pub const AUTH_CMD_SN: u8 = 0x02;
pub const AUTH_RSP_MAC_FW: u8 = 0x81;
pub const AUTH_RSP_SN: u8 = 0x82;

pub const SVC_CTL_UUID: Uuid = Uuid::from_u128(0x00009100_0000_1000_8000_57616c6b697a);
pub const CHR_CTL_WRITE_UUID: Uuid = Uuid::from_u128(0x00009101_0000_1000_8000_57616c6b697a);
pub const CHR_CTL_NOTIFY_UUID: Uuid = Uuid::from_u128(0x00009102_0000_1000_8000_57616c6b697a);

pub const SVC_BATTERY_UUID: Uuid = Uuid::from_u128(0x0000180f_0000_1000_8000_00805f9b34fb);
pub const CHR_BATTERY_LEVEL_UUID: Uuid = Uuid::from_u128(0x00002a19_0000_1000_8000_00805f9b34fb);

pub const SVC_DIS_UUID: Uuid = Uuid::from_u128(0x0000180a_0000_1000_8000_00805f9b34fb);
pub const CHR_FW_REV_UUID: Uuid = Uuid::from_u128(0x00002a26_0000_1000_8000_00805f9b34fb);

pub const FRAME_MAGIC: [u8; 4] = [0xFC, 0xFC, 0xFC, 0xFC];
pub const WRITE_CHUNK_BYTES: usize = 180;
pub const NOMINAL_STORAGE_TOTAL_MB: u64 = 64 * 1024;

/// 构造 `0x9000` 通道 AES-128-ECB 加密指令帧（16 字节定长零填充）。
pub fn encode_auth_cmd(cmd: u8, payload: &[u8]) -> [u8; 16] {
    let mut block = [0u8; 16];
    block[0] = cmd;
    let copy_len = payload.len().min(15);
    block[1..1 + copy_len].copy_from_slice(&payload[..copy_len]);
    let cipher = Aes128::new(GenericArray::from_slice(&AUTH_AES_KEY));
    cipher.encrypt_block(GenericArray::from_mut_slice(&mut block));
    block
}

/// 解密 `0x9002` 收到的 AES-128-ECB 16 字节响应帧。
pub fn decrypt_auth_frame(cipher_bytes: &[u8]) -> Option<[u8; 16]> {
    if cipher_bytes.len() < 16 {
        return None;
    }
    let mut block = [0u8; 16];
    block.copy_from_slice(&cipher_bytes[..16]);
    let cipher = Aes128::new(GenericArray::from_slice(&AUTH_AES_KEY));
    cipher.decrypt_block(GenericArray::from_mut_slice(&mut block));
    Some(block)
}

fn format_mac(bytes: &[u8]) -> Option<String> {
    if bytes.len() < 6 {
        return None;
    }
    Some(format!(
        "{:02X}:{:02X}:{:02X}:{:02X}:{:02X}:{:02X}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]
    ))
}

/// 解析 `0x9000` `0x01 -> 0x81` 明文应答：`[0x81, mac[0..6], flags[2], maj, min, pat, ...]`。
pub fn parse_auth_mac_fw(plain: &[u8; 16]) -> Option<(String, String)> {
    if plain[0] != AUTH_RSP_MAC_FW {
        return None;
    }
    let mac = format_mac(&plain[1..7])?;
    let fw = format!("{}.{}.{}", plain[9], plain[10], plain[11]);
    Some((mac, fw))
}

/// 解析 `0x9000` `0x02 -> 0x82` 明文应答：`[0x82, SN ASCII..., 0x00...]`。
pub fn parse_auth_sn(plain: &[u8; 16]) -> Option<String> {
    if plain[0] != AUTH_RSP_SN {
        return None;
    }
    let end = plain[1..].iter().position(|&b| b == 0).unwrap_or(15);
    let raw = std::str::from_utf8(&plain[1..1 + end]).ok()?.trim();
    if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_graphic()) {
        return None;
    }
    Some(raw.to_string())
}

/// 解析 `0x544A` 厂商广播载荷中的 6 字节设备 MAC。
pub fn parse_mfg_data_544a(bytes: &[u8]) -> Option<String> {
    format_mac(bytes)
}

/// 解析 `0x544A` 厂商广播载荷尾部的 3 字节固件版本（若有效）。
pub fn parse_mfg_fw_544a(bytes: &[u8]) -> Option<String> {
    if bytes.len() < 11 {
        return None;
    }
    let (maj, min, pat) = (bytes[8], bytes[9], bytes[10]);
    if maj == 0 && min == 0 && pat == 0 {
        return None;
    }
    Some(format!("{maj}.{min}.{pat}"))
}

/// GetSeed `>= 0.2.5` 固件启用了官方云端「一机一码」鉴权锁（未经云端私钥解锁，`0x9100` 静默丢弃指令）。
pub fn is_cloud_auth_locked_fw(fw: &str) -> bool {
    let clean = fw
        .trim()
        .trim_start_matches('v')
        .trim_start_matches('V');
    if clean.is_empty() {
        return false;
    }
    let mut parts = clean
        .split(['-', '+'])
        .next()
        .unwrap_or("")
        .split('.')
        .filter_map(|p| p.parse::<u32>().ok());
    let (Some(maj), Some(min), Some(pat)) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    (maj, min, pat) >= (0, 2, 5)
}

/// 根据 GATT ATT MTU 计算安全的写特征分片大小（`20..=244`，未知 MTU 时退回 `180`）。
pub fn write_chunk_bytes_for_mtu(mtu: Option<u16>) -> usize {
    mtu.map(|m| usize::from(m).saturating_sub(3).clamp(20, 244))
        .unwrap_or(WRITE_CHUNK_BYTES)
}

pub const CMD_STORAGE: u16 = 0x0042;
pub const CMD_FILE_LIST: u16 = 0x0043;
pub const CMD_DELETE_FILE: u16 = 0x0044;
pub const CMD_GET_TIME: u16 = 0x0046;
pub const CMD_SET_TIME: u16 = 0x0146;
pub const CMD_STATUS: u16 = 0x0050;
pub const CMD_PULL_FILE: u16 = 0x0145;

pub const RSP_PULL_START: u16 = 0x0245;
pub const RSP_PULL_DATA: u16 = 0x0345;
pub const RSP_PULL_END: u16 = 0x0445;
pub const RSP_PULL_ERR: u16 = 0x0545;

/// 组帧：`FCFCFCFC` + `cmd (u16 LE)` + `len (u16 LE)` + `body` + `CRC32 (u32 LE)`。
pub fn encode_packet(cmd: u16, body: &[u8]) -> Result<Vec<u8>, SdkError> {
    let body_len = u16::try_from(body.len())
        .map_err(|_| SdkError::Protocol("GetSeed 指令负载超过 64KB".into()))?;
    let mut pkt = Vec::with_capacity(12 + body.len());
    pkt.extend_from_slice(&FRAME_MAGIC);
    pkt.extend_from_slice(&cmd.to_le_bytes());
    pkt.extend_from_slice(&body_len.to_le_bytes());
    pkt.extend_from_slice(body);
    let crc = crc32fast::hash(&pkt);
    pkt.extend_from_slice(&crc.to_le_bytes());
    Ok(pkt)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedFrame {
    pub cmd: u16,
    pub body: Vec<u8>,
}

/// BLE 通知分片重组器（按 `FC FC FC FC` 魔数对齐并校验 CRC32）。
#[derive(Default)]
pub struct FrameStreamParser {
    buf: Vec<u8>,
}

impl FrameStreamParser {
    pub fn push(&mut self, chunk: &[u8]) -> Vec<DecodedFrame> {
        self.buf.extend_from_slice(chunk);
        let mut out = Vec::new();
        loop {
            let Some(magic_pos) = self.buf.windows(4).position(|w| w == FRAME_MAGIC) else {
                // Keep at most 3 trailing bytes in case FRAME_MAGIC splits across notifications.
                let keep = self.buf.len().saturating_sub(3);
                if keep > 0 {
                    self.buf.drain(..keep);
                }
                break;
            };
            if magic_pos > 0 {
                self.buf.drain(..magic_pos);
            }
            if self.buf.len() < 12 {
                break;
            }
            let cmd = u16::from_le_bytes([self.buf[4], self.buf[5]]);
            let body_len = u16::from_le_bytes([self.buf[6], self.buf[7]]) as usize;
            let total_len = 12 + body_len;
            if self.buf.len() < total_len {
                break;
            }
            let expected_crc = u32::from_le_bytes([
                self.buf[total_len - 4],
                self.buf[total_len - 3],
                self.buf[total_len - 2],
                self.buf[total_len - 1],
            ]);
            let actual_crc = crc32fast::hash(&self.buf[..total_len - 4]);
            if actual_crc == expected_crc {
                let body = self.buf[8..8 + body_len].to_vec();
                out.push(DecodedFrame { cmd, body });
                self.buf.drain(..total_len);
            } else {
                // Bad CRC: skip the first magic byte to re-synchronize.
                self.buf.drain(..1);
            }
        }
        out
    }
}

pub fn format_time_sync_ascii(local_dt: DateTime<Local>) -> Vec<u8> {
    local_dt.format("%Y%m%d%H%M%S").to_string().into_bytes()
}

pub fn parse_storage_free_kb(body: &[u8]) -> Option<u32> {
    if body.len() < 8 {
        return None;
    }
    Some(u32::from_le_bytes([body[4], body[5], body[6], body[7]]))
}

fn parse_local_timestamp_sec(s: &str, fmt: &str) -> Option<i64> {
    let naive = NaiveDateTime::parse_from_str(s.trim(), fmt).ok()?;
    Local
        .from_local_datetime(&naive)
        .earliest()
        .map(|dt| dt.timestamp())
}

fn parse_filename_start_sec(filename: &str) -> Option<i64> {
    let stem = filename
        .trim()
        .rsplit('/')
        .next()
        .unwrap_or(filename)
        .split('.')
        .next()?;
    parse_local_timestamp_sec(stem, "%Y-%m-%d-%H-%M-%S")
}

/// 解析 `0x0043` UTF-8 CSV：`idx,filename,mtime,size;...`（空载荷表示无文件）。
pub fn parse_file_list_csv(body: &[u8]) -> Vec<SdkFileEntry> {
    let text = String::from_utf8_lossy(body);
    let mut files = Vec::new();
    for raw_item in text.split(';') {
        let item = raw_item.trim();
        if item.is_empty() {
            continue;
        }
        let parts: Vec<&str> = item.split(',').map(str::trim).collect();
        if parts.len() < 4 {
            continue;
        }
        let name = parts[1];
        if name.is_empty() {
            continue;
        }
        let index = parts[0].parse::<u32>().ok();
        let created_at = parse_local_timestamp_sec(parts[2], "%Y-%m-%d %H:%M:%S");
        let start_at = parse_filename_start_sec(name).or(created_at);
        let size = parts[3].parse::<u64>().unwrap_or(0);
        files.push(SdkFileEntry {
            name: name.to_string(),
            size,
            index,
            created_at,
            session: None,
            seq: None,
            start_at,
            synced: Some(false),
        });
    }
    files
}

/// `0x0145` 文件拉取状态机（处理 `0x0245 / 0x0345 / 0x0445 / 0x0545` 分片）。
#[derive(Default)]
pub struct PullAssembler {
    buf: Vec<u8>,
    expected_size: Option<usize>,
    done: bool,
}

impl PullAssembler {
    pub fn is_done(&self) -> bool {
        self.done
    }

    pub fn take_bytes(self) -> Vec<u8> {
        self.buf
    }

    pub fn handle_frame(&mut self, cmd: u16, body: &[u8]) -> Result<bool, SdkError> {
        match cmd {
            RSP_PULL_START => {
                if body.len() < 4 {
                    return Err(SdkError::Protocol("GetSeed PULL_START 长度不足".into()));
                }
                let size = u32::from_le_bytes([body[0], body[1], body[2], body[3]]) as usize;
                // Cap sanity allocation at 256MB per single BLE recording file.
                let capped = size.min(256 * 1024 * 1024);
                self.expected_size = Some(capped);
                self.buf.resize(capped, 0);
                Ok(false)
            }
            RSP_PULL_DATA => {
                if body.len() < 4 {
                    return Err(SdkError::Protocol("GetSeed PULL_DATA 长度不足".into()));
                }
                let end_offset = u32::from_le_bytes([body[0], body[1], body[2], body[3]]) as usize;
                let payload = &body[4..];
                if !payload.is_empty() {
                    let start = end_offset.saturating_sub(payload.len());
                    let actual_end = start.saturating_add(payload.len());
                    if actual_end > self.buf.len() {
                        self.buf.resize(actual_end, 0);
                    }
                    self.buf[start..actual_end].copy_from_slice(payload);
                }
                Ok(false)
            }
            RSP_PULL_END => {
                if body.len() >= 4 {
                    let done_size =
                        u32::from_le_bytes([body[0], body[1], body[2], body[3]]) as usize;
                    if done_size > 0 && done_size <= self.buf.len() {
                        self.buf.truncate(done_size);
                    }
                } else if let Some(exp) = self.expected_size {
                    if exp <= self.buf.len() {
                        self.buf.truncate(exp);
                    }
                }
                self.done = true;
                Ok(true)
            }
            RSP_PULL_ERR => {
                let code = body.first().copied().unwrap_or(0xFF);
                if code == 0x5A {
                    Err(SdkError::Protocol("GetSeed 设备中不存在指定文件 (0x5A)".into()))
                } else {
                    Err(SdkError::Protocol(format!(
                        "GetSeed 文件传输报错 (code=0x{code:02X})"
                    )))
                }
            }
            _ => Ok(false),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_and_reassembles_fragmented_frames_with_crc() {
        let f1 = encode_packet(CMD_STORAGE, &[1, 2, 3, 4, 0, 16, 0, 0, 0, 0, 0, 0]).unwrap();
        let f2 = encode_packet(CMD_DELETE_FILE, &[0x01]).unwrap();
        let mut combined = vec![0x00, 0xFF]; // noise prefix
        combined.extend_from_slice(&f1);
        combined.extend_from_slice(&f2);

        let mut parser = FrameStreamParser::default();
        let mut parsed = Vec::new();
        for chunk in combined.chunks(5) {
            parsed.extend(parser.push(chunk));
        }
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].cmd, CMD_STORAGE);
        assert_eq!(parse_storage_free_kb(&parsed[0].body), Some(4096));
        assert_eq!(parsed[1].cmd, CMD_DELETE_FILE);
        assert_eq!(parsed[1].body, vec![0x01]);
    }

    #[test]
    fn parses_file_list_csv_and_empty_body() {
        assert!(parse_file_list_csv(b"").is_empty());
        let sample = b"0,2026-10-10-15-06-15.ogg,2026-10-10 15:06:22,31282;1,2026-10-10-16-00-00.ogg,2026-10-10 16:00:10,1024;";
        let list = parse_file_list_csv(sample);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].index, Some(0));
        assert_eq!(list[0].name, "2026-10-10-15-06-15.ogg");
        assert_eq!(list[0].size, 31282);
        assert!(list[0].start_at.is_some());
        assert_eq!(list[1].name, "2026-10-10-16-00-00.ogg");
        assert_eq!(list[1].size, 1024);
    }

    #[test]
    fn reassembles_pull_chunks_by_end_offset() {
        let mut asm = PullAssembler::default();
        asm.handle_frame(RSP_PULL_START, &10u32.to_le_bytes()).unwrap();
        asm.handle_frame(RSP_PULL_DATA, &[5, 0, 0, 0, b'h', b'e', b'l', b'l', b'o'])
            .unwrap();
        let finished = asm
            .handle_frame(RSP_PULL_DATA, &[10, 0, 0, 0, b'w', b'o', b'r', b'l', b'd'])
            .unwrap();
        assert!(!finished);
        assert!(asm.handle_frame(RSP_PULL_END, &10u32.to_le_bytes()).unwrap());
        assert_eq!(asm.take_bytes(), b"helloworld");
    }

    #[test]
    fn encodes_and_decrypts_0x9000_aes_handshake_vectors() {
        // Real vector from Get-A7769D capture: cmd 0x01 & 0x02
        let tx_01 = encode_auth_cmd(AUTH_CMD_MAC_FW, &[]);
        assert_eq!(
            hex_lower(&tx_01),
            "8db70aadce8fa250492f38b063b2054f"
        );
        let tx_02 = encode_auth_cmd(AUTH_CMD_SN, &[]);
        assert_eq!(
            hex_lower(&tx_02),
            "77019a44159539ab45e67147f75845ea"
        );

        // Live 0x81 response from Get-A7769D -> MAC 5C:8E:8B:A7:76:9D, fw 0.2.7
        let rsp_01_cipher = [
            0x1b, 0x91, 0x6b, 0x59, 0x54, 0x0d, 0x76, 0x11, 0x0b, 0x84, 0x8d, 0x21, 0x25, 0x3b,
            0x24, 0x91,
        ];
        let plain_01 = decrypt_auth_frame(&rsp_01_cipher).unwrap();
        let (mac, fw) = parse_auth_mac_fw(&plain_01).unwrap();
        assert_eq!(mac, "5C:8E:8B:A7:76:9D");
        assert_eq!(fw, "0.2.7");

        // Reference A105 response -> fw 0.1.8
        let rsp_01_legacy = [
            0x0e, 0x83, 0x87, 0x91, 0x54, 0xaa, 0xcb, 0xed, 0x3e, 0x85, 0x68, 0xd2, 0x3f, 0x1c,
            0x2a, 0x02,
        ];
        let (mac_old, fw_old) = parse_auth_mac_fw(&decrypt_auth_frame(&rsp_01_legacy).unwrap()).unwrap();
        assert_eq!(mac_old, "5C:8E:8B:A7:8A:67");
        assert_eq!(fw_old, "0.1.8");

        // Live 0x82 response from Get-A7769D -> SN GET25LA7769D
        let rsp_02_cipher = [
            0x6d, 0x61, 0x24, 0xa4, 0xeb, 0xa8, 0x1c, 0x03, 0x15, 0x23, 0xd9, 0xf1, 0x04, 0x58,
            0x82, 0x08,
        ];
        let sn = parse_auth_sn(&decrypt_auth_frame(&rsp_02_cipher).unwrap()).unwrap();
        assert_eq!(sn, "GET25LA7769D");

        // MFD 0x544A parsing + fw lock boundary + MTU chunk sizing
        let mfd = [0x5c, 0x8e, 0x8b, 0xa7, 0x76, 0x9d, 0x00, 0x00, 0x00, 0x02, 0x07];
        assert_eq!(parse_mfg_data_544a(&mfd).as_deref(), Some("5C:8E:8B:A7:76:9D"));
        assert_eq!(parse_mfg_fw_544a(&mfd).as_deref(), Some("0.2.7"));

        assert!(!is_cloud_auth_locked_fw("0.1.8"));
        assert!(!is_cloud_auth_locked_fw("v0.2.4"));
        assert!(is_cloud_auth_locked_fw("0.2.5"));
        assert!(is_cloud_auth_locked_fw("0.2.7"));
        assert!(!is_cloud_auth_locked_fw(""));

        assert_eq!(write_chunk_bytes_for_mtu(None), 180);
        assert_eq!(write_chunk_bytes_for_mtu(Some(23)), 20);
        assert_eq!(write_chunk_bytes_for_mtu(Some(495)), 244);
    }

    fn hex_lower(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }
}
