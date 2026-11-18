//! D3200 帧、目录、ECDH 会话密钥与 Ogg Opus 封装。不碰蓝牙。

use aes::Aes256;
use cipher::{KeyIvInit, StreamCipher};
use ctr::Ctr128BE;
use hkdf::Hkdf;
use p256::ecdh::diffie_hellman;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use rand_core::OsRng;
use reai_ext_sdk::SdkError;
use sha2::Sha256;
use uuid::Uuid;

pub const SERVICE_UUID: Uuid = Uuid::from_u128(0x020cf5da_0000_1000_8000_00805f9b34fb);
pub const WRITE_UUID: Uuid = Uuid::from_u128(0x00007777_0000_1000_8000_00805f9b34fb);
pub const NOTIFY_UUID: Uuid = Uuid::from_u128(0x00008888_0000_1000_8000_00805f9b34fb);

const FILE_MAGIC: &[u8] = b"soundcored3200";
const OGG_SERIAL: u32 = 0x4152_4b52;

pub const CMD_INFO: (u8, u8) = (0x01, 0x01);
pub const CMD_SYNC_TIME: (u8, u8) = (0x01, 0xA6);
pub const CMD_RECORD: (u8, u8) = (0x18, 0x82);
pub const CMD_LIST: (u8, u8) = (0x1B, 0x0E);
pub const CMD_TRANSFER: (u8, u8) = (0x1A, 0x07);
pub const CMD_DELETE: (u8, u8) = (0x1A, 0x10);
pub const CMD_HANDSHAKE: (u8, u8) = (0x2E, 0x01);

type Aes256Ctr = Ctr128BE<Aes256>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceInfo {
    pub battery: u8,
    pub charging: bool,
    pub firmware: String,
    pub serial: String,
    pub total_kb: u32,
    pub free_kb: u32,
    pub record_status: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectoryEntry {
    pub id: u32,
    pub ended_at: u32,
    pub duration_ms: u32,
}

pub struct Packets {
    buffer: Vec<u8>,
}

impl Packets {
    pub fn new() -> Self {
        Self { buffer: Vec::new() }
    }

    pub fn feed(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(data);
        let mut out = Vec::new();
        loop {
            if self.buffer.len() < 10 {
                break;
            }
            let start = self
                .buffer
                .windows(4)
                .position(|w| w == [0x09, 0xFF, 0x00, 0x00]);
            let Some(start) = start else {
                let keep = self.buffer.len().min(3);
                self.buffer.drain(..self.buffer.len() - keep);
                break;
            };
            if start > 0 {
                self.buffer.drain(..start);
            }
            if self.buffer.len() < 10 {
                break;
            }
            let size = u16::from_le_bytes([self.buffer[7], self.buffer[8]]) as usize;
            if size < 10 {
                self.buffer.drain(..1);
                continue;
            }
            if self.buffer.len() < size {
                break;
            }
            let raw: Vec<u8> = self.buffer.drain(..size).collect();
            let sum = raw[..raw.len() - 1]
                .iter()
                .fold(0u8, |acc, b| acc.wrapping_add(*b));
            if sum == *raw.last().unwrap_or(&0) {
                out.push(raw);
            }
        }
        out
    }
}

pub fn command(kind: u8, ident: u8, payload: &[u8]) -> Vec<u8> {
    frame(0x08, 0xEE, kind, ident, 0, payload)
}

#[cfg(test)]
pub fn response(kind: u8, ident: u8, status: u8, payload: &[u8]) -> Vec<u8> {
    frame(0x09, 0xFF, kind, ident, status, payload)
}

fn frame(magic0: u8, magic1: u8, kind: u8, ident: u8, status: u8, payload: &[u8]) -> Vec<u8> {
    let total = 10 + payload.len();
    let mut raw = Vec::with_capacity(total);
    raw.extend_from_slice(&[magic0, magic1, 0x00, 0x00, status, kind, ident]);
    raw.extend_from_slice(&(total as u16).to_le_bytes());
    raw.extend_from_slice(payload);
    let sum = raw.iter().fold(0u8, |acc, b| acc.wrapping_add(*b));
    raw.push(sum);
    raw
}

pub fn payload_of(frame: &[u8]) -> Result<&[u8], SdkError> {
    if frame.len() < 10 {
        return Err(SdkError::Protocol("帧长度不足".into()));
    }
    let size = u16::from_le_bytes([frame[7], frame[8]]) as usize;
    if size != frame.len() || size < 10 {
        return Err(SdkError::Protocol("帧长度字段与实际不符".into()));
    }
    Ok(&frame[9..size - 1])
}

pub fn status_ok(frame: &[u8]) -> bool {
    frame.len() > 4 && (frame[4] & 0x0f) == 1
}

pub fn battery_percent(value: u8) -> u8 {
    let value = value & 0x7f;
    if value <= 9 {
        value.saturating_add(1).saturating_mul(10)
    } else {
        value.min(100)
    }
}

fn ascii_field(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).trim().to_string()
}

pub fn parse_info(payload: &[u8]) -> Result<DeviceInfo, SdkError> {
    if payload.len() < 32 {
        return Err(SdkError::Protocol("设备信息不完整".into()));
    }
    let serial = ascii_field(&payload[8..24]).to_ascii_lowercase();
    if serial.is_empty() {
        return Err(SdkError::Protocol("设备没有返回有效序列号".into()));
    }
    let record_status = payload
        .get(50)
        .copied()
        .filter(|v| *v <= 2)
        .unwrap_or(0);
    Ok(DeviceInfo {
        battery: battery_percent(payload[1]),
        charging: payload[2] == 1,
        firmware: ascii_field(&payload[3..8]),
        serial,
        total_kb: u32::from_le_bytes(payload[24..28].try_into().unwrap()),
        free_kb: u32::from_le_bytes(payload[28..32].try_into().unwrap()),
        record_status,
    })
}

pub fn parse_directory(payload: &[u8]) -> Result<(Vec<DirectoryEntry>, u16), SdkError> {
    if payload.len() < 2 {
        return Err(SdkError::Protocol("设备录音目录不完整".into()));
    }
    let count = u16::from_le_bytes([payload[0], payload[1]]);
    let need = 2 + count as usize * 12 + 8;
    if payload.len() < need {
        return Err(SdkError::Protocol("设备录音目录不完整".into()));
    }
    let mut rows = Vec::with_capacity(count as usize);
    for index in 0..count as usize {
        let offset = 2 + index * 12;
        let id = u32::from_le_bytes(payload[offset..offset + 4].try_into().unwrap());
        let ended_at = u32::from_le_bytes(payload[offset + 4..offset + 8].try_into().unwrap());
        let duration_ms = u32::from_le_bytes(payload[offset + 8..offset + 12].try_into().unwrap());
        rows.push(DirectoryEntry {
            id,
            ended_at,
            duration_ms,
        });
    }
    Ok((rows, count))
}

pub fn file_id_from_name(name: &str) -> Result<u32, SdkError> {
    let stem = name
        .trim()
        .trim_end_matches(".opus")
        .trim_end_matches(".ogg")
        .trim_end_matches(".wav");
    stem.parse::<u32>()
        .map_err(|_| SdkError::Protocol(format!("无法从文件名解析录音编号：{name}")))
}

pub fn crypt_ctr(key: &[u8], iv: &[u8], data: &[u8]) -> Result<Vec<u8>, SdkError> {
    let mut cipher = Aes256Ctr::new_from_slices(key, iv)
        .map_err(|_| SdkError::Protocol("AES-CTR 密钥或计数器长度不正确".into()))?;
    let mut buf = data.to_vec();
    cipher.apply_keystream(&mut buf);
    Ok(buf)
}

fn hkdf_session(shared: &[u8]) -> Result<[u8; 32], SdkError> {
    let hk = Hkdf::<Sha256>::new(Some(&[0x01, 0x02, 0x03]), shared);
    let mut okm = [0u8; 32];
    hk.expand(&[0x01, 0x02, 0x03], &mut okm)
        .map_err(|_| SdkError::Protocol("会话密钥派生失败".into()))?;
    Ok(okm)
}

pub struct DeviceCrypto {
    secret: SecretKey,
    pub session_key: Option<[u8; 32]>,
}

impl DeviceCrypto {
    pub fn generate() -> Self {
        Self {
            secret: SecretKey::random(&mut OsRng),
            session_key: None,
        }
    }

    pub fn public_key(&self) -> Vec<u8> {
        self.secret
            .public_key()
            .to_encoded_point(false)
            .as_bytes()
            .to_vec()
    }

    fn shared_with(&self, peer_pub: &[u8]) -> Result<[u8; 32], SdkError> {
        let peer = PublicKey::from_sec1_bytes(peer_pub)
            .map_err(|_| SdkError::Protocol("对端公钥无法解析".into()))?;
        let shared = diffie_hellman(self.secret.to_nonzero_scalar(), peer.as_affine());
        let mut out = [0u8; 32];
        out.copy_from_slice(shared.raw_secret_bytes());
        Ok(out)
    }

    pub fn accept_peer(&mut self, payload: &[u8]) -> Result<(), SdkError> {
        if payload.len() < 97 {
            return Err(SdkError::Protocol("ECDH 握手不完整".into()));
        }
        let shared = self.shared_with(&payload[..65])?;
        if shared.as_slice() != &payload[65..97] {
            return Err(SdkError::Protocol("ECDH 握手校验失败".into()));
        }
        self.session_key = Some(hkdf_session(&shared)?);
        Ok(())
    }

    /// 测试用对端：用自己的私钥回答 App 公钥，返回设备载荷和会话密钥。
    #[cfg(test)]
    pub fn answer_peer(&self, peer_pub: &[u8]) -> Result<(Vec<u8>, [u8; 32]), SdkError> {
        let shared = self.shared_with(peer_pub)?;
        let mut payload = self.public_key();
        payload.extend_from_slice(&shared);
        Ok((payload, hkdf_session(&shared)?))
    }

    pub fn open_file_key(&self, payload: &[u8], expected_id: u32) -> Result<FileSecret, SdkError> {
        let key = self
            .session_key
            .ok_or_else(|| SdkError::Protocol("尚未完成密钥交换".into()))?;
        if payload.len() < 87 {
            return Err(SdkError::Protocol("录音文件头不完整".into()));
        }
        let ident = u32::from_le_bytes(payload[0..4].try_into().unwrap());
        let size = u32::from_le_bytes(payload[4..8].try_into().unwrap());
        if ident != expected_id {
            return Err(SdkError::Protocol("返回的录音文件标识不匹配".into()));
        }
        if payload[86] != 0 {
            return Err(SdkError::Protocol(format!(
                "设备拒绝导出（错误码 {}）",
                payload[86]
            )));
        }
        let plain = crypt_ctr(&key, &payload[70..86], &payload[24..70])?;
        if plain.len() < 46 || &plain[..FILE_MAGIC.len()] != FILE_MAGIC {
            return Err(SdkError::Protocol("录音文件密钥校验失败".into()));
        }
        let mut file_key = [0u8; 32];
        file_key.copy_from_slice(&plain[14..46]);
        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(&payload[8..20]);
        Ok(FileSecret {
            file_key,
            nonce,
            size,
        })
    }
}

#[derive(Debug, Clone)]
pub struct FileSecret {
    pub file_key: [u8; 32],
    pub nonce: [u8; 12],
    #[allow(dead_code)]
    pub size: u32,
}

impl FileSecret {
    pub fn decrypt_frame(&self, seq: u32, cipher: &[u8]) -> Result<Vec<u8>, SdkError> {
        let counter = (seq as u64)
            .checked_mul(10)
            .filter(|v| *v <= u32::MAX as u64)
            .ok_or_else(|| SdkError::Protocol("音频序号超出计数范围".into()))?;
        let mut iv = [0u8; 16];
        iv[..12].copy_from_slice(&self.nonce);
        iv[12..].copy_from_slice(&(counter as u32).to_be_bytes());
        crypt_ctr(&self.file_key, &iv, cipher)
    }
}

pub fn slice_units(payload: &[u8]) -> Result<Vec<(u32, Vec<u8>)>, SdkError> {
    if payload.len() % 166 != 0 {
        return Err(SdkError::Protocol("音频分片长度异常".into()));
    }
    let mut units = Vec::with_capacity(payload.len() / 166);
    for chunk in payload.chunks(166) {
        let seq = u32::from_le_bytes(chunk[0..4].try_into().unwrap());
        units.push((seq, chunk[5..165].to_vec()));
    }
    Ok(units)
}

fn ogg_crc(data: &[u8]) -> u32 {
    const TABLE: [u32; 256] = {
        let mut table = [0u32; 256];
        let mut index = 0;
        while index < 256 {
            let mut value = (index as u32) << 24;
            let mut bit = 0;
            while bit < 8 {
                if value & 0x8000_0000 != 0 {
                    value = (value << 1) ^ 0x04c1_1db7;
                } else {
                    value <<= 1;
                }
                bit += 1;
            }
            table[index] = value;
            index += 1;
        }
        table
    };
    let mut crc = 0u32;
    for byte in data {
        let lookup = ((crc >> 24) ^ u32::from(*byte)) as usize & 0xff;
        crc = (crc << 8) ^ TABLE[lookup];
    }
    crc
}

fn ogg_page(packets: &[Vec<u8>], sequence: u32, granule: u64, flags: u8) -> Vec<u8> {
    let segments: Vec<u8> = packets.iter().map(|p| p.len() as u8).collect();
    let mut page = Vec::with_capacity(27 + segments.len() + packets.iter().map(Vec::len).sum::<usize>());
    page.extend_from_slice(b"OggS");
    page.extend_from_slice(&[0, flags]);
    page.extend_from_slice(&granule.to_le_bytes());
    page.extend_from_slice(&OGG_SERIAL.to_le_bytes());
    page.extend_from_slice(&sequence.to_le_bytes());
    page.extend_from_slice(&0u32.to_le_bytes());
    page.push(segments.len() as u8);
    page.extend_from_slice(&segments);
    for packet in packets {
        page.extend_from_slice(packet);
    }
    let crc = ogg_crc(&page);
    page[22..26].copy_from_slice(&crc.to_le_bytes());
    page
}

pub fn mux_ogg(frames: &[Vec<u8>]) -> Result<Vec<u8>, SdkError> {
    if frames.is_empty() {
        return Err(SdkError::Protocol("录音数据为空".into()));
    }
    let mut head = b"OpusHead".to_vec();
    head.extend_from_slice(&1u8.to_le_bytes());
    head.extend_from_slice(&1u8.to_le_bytes());
    head.extend_from_slice(&3840u16.to_le_bytes());
    head.extend_from_slice(&48_000u32.to_le_bytes());
    head.extend_from_slice(&0i16.to_le_bytes());
    head.push(0);
    let vendor = b"D3200 Local";
    let mut tags = b"OpusTags".to_vec();
    tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    tags.extend_from_slice(vendor);
    tags.extend_from_slice(&0u32.to_le_bytes());

    let mut pages = Vec::new();
    pages.extend(ogg_page(&[head], 0, 0, 2));
    pages.extend(ogg_page(&[tags], 1, 0, 0));
    for (index, batch_start) in (0..frames.len()).step_by(50).enumerate() {
        let end = (batch_start + 50).min(frames.len());
        let batch: Vec<Vec<u8>> = frames[batch_start..end]
            .iter()
            .map(|frame| {
                let trimmed = frame
                    .iter()
                    .rposition(|b| *b != 0)
                    .map(|pos| frame[..=pos].to_vec())
                    .unwrap_or_else(|| vec![0]);
                trimmed
            })
            .collect();
        let granule = (end as u64) * 960;
        let flags = if end == frames.len() { 4 } else { 0 };
        pages.extend(ogg_page(&batch, index as u32 + 2, granule, flags));
    }
    Ok(pages)
}

#[cfg(test)]
pub fn seal_file_head(
    session_key: &[u8; 32],
    id: u32,
    frame_count: u32,
    file_key: &[u8; 32],
    nonce: &[u8; 12],
    session_nonce: &[u8; 16],
) -> Result<Vec<u8>, SdkError> {
    let mut material = [0u8; 46];
    material[..FILE_MAGIC.len()].copy_from_slice(FILE_MAGIC);
    material[14..46].copy_from_slice(file_key);
    let encrypted = crypt_ctr(session_key, session_nonce, &material)?;
    let mut payload = vec![0u8; 87];
    payload[0..4].copy_from_slice(&id.to_le_bytes());
    payload[4..8].copy_from_slice(&(frame_count.saturating_mul(166)).to_le_bytes());
    payload[8..20].copy_from_slice(nonce);
    payload[24..70].copy_from_slice(&encrypted);
    payload[70..86].copy_from_slice(session_nonce);
    Ok(payload)
}

#[cfg(test)]
pub fn seal_frame(secret: &FileSecret, seq: u32, plain: &[u8]) -> Result<[u8; 166], SdkError> {
    let mut block = [0u8; 160];
    if plain.len() > 160 {
        return Err(SdkError::Protocol("音频帧超过 160 字节".into()));
    }
    block[..plain.len()].copy_from_slice(plain);
    let cipher = secret.decrypt_frame(seq, &block)?;
    let mut unit = [0u8; 166];
    unit[0..4].copy_from_slice(&seq.to_le_bytes());
    unit[5..165].copy_from_slice(&cipher);
    Ok(unit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_checksum_matches_known_info_request() {
        assert_eq!(command(0x01, 0x01, &[]), hex_to("08ee00000001010a0002"));
    }

    #[test]
    fn parser_accepts_a_split_info_frame() {
        let info = sample_info_payload();
        let frame = response(0x01, 0x01, 1, &info);
        let mut parser = Packets::new();
        assert!(parser.feed(&frame[..4]).is_empty());
        let got = parser.feed(&frame[4..]);
        assert_eq!(got.len(), 1);
        let parsed = parse_info(payload_of(&got[0]).unwrap()).unwrap();
        assert_eq!(parsed.serial, "007f1d04cca3");
        assert_eq!(parsed.firmware, "04.92");
        assert_eq!(parsed.battery, 80);
        assert!(parsed.charging);
        assert_eq!(parsed.total_kb, 8 * 1024 * 1024);
        assert_eq!(parsed.free_kb, 6 * 1024 * 1024);
        assert_eq!(parsed.record_status, 0);
    }

    #[test]
    fn directory_keeps_id_end_and_duration() {
        let mut payload = vec![1, 0];
        payload.extend_from_slice(&1_700_000_000u32.to_le_bytes());
        payload.extend_from_slice(&1_700_000_040u32.to_le_bytes());
        payload.extend_from_slice(&40u32.to_le_bytes());
        payload.extend_from_slice(&[0u8; 8]);
        let (rows, count) = parse_directory(&payload).unwrap();
        assert_eq!(count, 1);
        assert_eq!(rows[0].id, 1_700_000_000);
        assert_eq!(rows[0].duration_ms, 40);
    }

    #[test]
    fn ecdh_and_file_key_roundtrip() {
        let mut app = DeviceCrypto::generate();
        let device = DeviceCrypto::generate();
        let (peer_payload, device_key) = device.answer_peer(&app.public_key()).unwrap();
        app.accept_peer(&peer_payload).unwrap();
        assert_eq!(app.session_key.unwrap(), device_key);

        let file_key = [9u8; 32];
        let nonce = [3u8; 12];
        let session_nonce = [7u8; 16];
        let head = seal_file_head(
            &device_key,
            42,
            1,
            &file_key,
            &nonce,
            &session_nonce,
        )
        .unwrap();
        let opened = app.open_file_key(&head, 42).unwrap();
        assert_eq!(opened.file_key, file_key);
        let plain = b"abc";
        let unit = seal_frame(&opened, 0, plain).unwrap();
        let back = opened.decrypt_frame(0, &unit[5..165]).unwrap();
        assert_eq!(&back[..3], plain);
        assert!(back[3..].iter().all(|b| *b == 0));
    }

    #[test]
    fn ogg_crc_matches_reference_page() {
        let mut header = b"OpusHead".to_vec();
        header.extend_from_slice(&[1, 1]);
        header.extend_from_slice(&3840u16.to_le_bytes());
        header.extend_from_slice(&48_000u32.to_le_bytes());
        header.extend_from_slice(&0i16.to_le_bytes());
        header.push(0);
        let page = ogg_page(&[header], 0, 0, 2);
        assert_eq!(&page[..4], b"OggS");
        assert_eq!(u32::from_le_bytes(page[22..26].try_into().unwrap()), 0x2da0_6707);
        assert_eq!(
            ogg_crc(b"OggS\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"),
            0xeca6_dc55
        );
    }

    fn sample_info_payload() -> Vec<u8> {
        let mut payload = vec![0u8; 51];
        payload[1] = 7;
        payload[2] = 1;
        payload[3..8].copy_from_slice(b"04.92");
        payload[8..20].copy_from_slice(b"007F1D04CCA3");
        payload[24..28].copy_from_slice(&(8 * 1024 * 1024u32).to_le_bytes());
        payload[28..32].copy_from_slice(&(6 * 1024 * 1024u32).to_le_bytes());
        payload
    }

    fn hex_to(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }
}
