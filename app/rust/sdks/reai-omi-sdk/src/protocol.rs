use reai_ext_sdk::audio::{
    decode_pcm_le_to_16k_mono, decode_ulaw_to_16k_mono, Lc3WorkBufs, OpusLiveDecoder,
    decode_lc3_16k_10ms_frame,
};
use reai_ext_sdk::SdkError;
use uuid::Uuid;

pub const SVC_OMI_AUDIO_UUID: Uuid = Uuid::from_u128(0x19b10000_e8f2_537e_4f6c_d104768a1214);
pub const CHR_OMI_AUDIO_DATA_UUID: Uuid = Uuid::from_u128(0x19b10001_e8f2_537e_4f6c_d104768a1214);
pub const CHR_OMI_AUDIO_CODEC_UUID: Uuid = Uuid::from_u128(0x19b10002_e8f2_537e_4f6c_d104768a1214);

pub const SVC_OMI_SETTINGS_UUID: Uuid = Uuid::from_u128(0x19b10010_e8f2_537e_4f6c_d104768a1214);
pub const CHR_OMI_CHARGING_UUID: Uuid = Uuid::from_u128(0x19b10013_e8f2_537e_4f6c_d104768a1214);
pub const CHR_OMI_MUTE_UUID: Uuid = Uuid::from_u128(0x19b10015_e8f2_537e_4f6c_d104768a1214);

pub const SVC_OMI_BUTTON_UUID: Uuid = Uuid::from_u128(0x23ba7924_0000_1000_7450_346eac492e92);
pub const CHR_OMI_BUTTON_TRIGGER_UUID: Uuid =
    Uuid::from_u128(0x23ba7925_0000_1000_7450_346eac492e92);

pub const SVC_OMI_TIMESYNC_UUID: Uuid = Uuid::from_u128(0x19b10030_e8f2_537e_4f6c_d104768a1214);
pub const CHR_OMI_TIMESYNC_WRITE_UUID: Uuid =
    Uuid::from_u128(0x19b10031_e8f2_537e_4f6c_d104768a1214);

pub const SVC_OMI_STORAGE_UUID: Uuid = Uuid::from_u128(0x30295780_4301_eabd_2904_2849adfeae43);
pub const CHR_OMI_STORAGE_DATA_UUID: Uuid =
    Uuid::from_u128(0x30295781_4301_eabd_2904_2849adfeae43);
pub const CHR_OMI_STORAGE_CTRL_UUID: Uuid =
    Uuid::from_u128(0x30295782_4301_eabd_2904_2849adfeae43);

pub const SVC_FRIEND_PENDANT_UUID: Uuid =
    Uuid::from_u128(0x1a3fd0e7_b1f3_ac9e_2e49_b647b2c4f8da);
pub const CHR_FRIEND_PENDANT_AUDIO_UUID: Uuid =
    Uuid::from_u128(0x01000000_1111_1111_1111_111111111111);

pub const SVC_BATTERY_UUID: Uuid = Uuid::from_u128(0x0000180f_0000_1000_8000_00805f9b34fb);
pub const CHR_BATTERY_LEVEL_UUID: Uuid = Uuid::from_u128(0x00002a19_0000_1000_8000_00805f9b34fb);

pub const SVC_DIS_UUID: Uuid = Uuid::from_u128(0x0000180a_0000_1000_8000_00805f9b34fb);
pub const CHR_MODEL_NUMBER_UUID: Uuid = Uuid::from_u128(0x00002a24_0000_1000_8000_00805f9b34fb);
pub const CHR_FW_REV_UUID: Uuid = Uuid::from_u128(0x00002a26_0000_1000_8000_00805f9b34fb);

pub const RING_CMD_STOP: u8 = 0x03;
pub const RING_CMD_INFO: u8 = 0x10;
pub const RING_CMD_READ: u8 = 0x11;
pub const RING_CMD_ADVANCE: u8 = 0x12;

pub const RING_NOTIFY_ACK: u8 = 0x01;
pub const RING_NOTIFY_INFO: u8 = 0x02;
pub const RING_NOTIFY_DATA: u8 = 0x03;
pub const RING_NOTIFY_DONE: u8 = 0x04;
pub const RING_NOTIFY_READ_BEGIN: u8 = 0x05;

pub const RING_RECORD_SIZE: usize = 444;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OmiAudioCodec {
    Pcm16,
    Pcm8,
    MuLaw16,
    MuLaw8,
    Opus,
    OpusFs320,
    Lc3Fs1030,
}

impl OmiAudioCodec {
    pub fn from_codec_id(id: u8) -> Self {
        match id {
            0 => Self::Pcm16,
            1 => Self::Pcm8,
            10 => Self::MuLaw16,
            11 => Self::MuLaw8,
            20 => Self::Opus,
            21 => Self::OpusFs320,
            _ => Self::Opus,
        }
    }
}

/// Omi CV1 BLE 3 字节包头重组器：`[packet_id: u16 LE][frag_idx: u8][payload...]`。
///
/// `frag_idx == 0` 表示新音频帧起点，此前累积的上一完整帧立即弹出，并监控 `packet_id` 丢包断档。
#[derive(Default)]
pub struct OmiPacketReassembler {
    last_packet_id: Option<u16>,
    pending_frame: Vec<u8>,
    expected_frag_idx: u8,
    corrupted_frame: bool,
    pending_discontinuous: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReassembledFrame {
    pub data: Vec<u8>,
    pub discontinuous: bool,
}

impl OmiPacketReassembler {
    pub fn push_packet(&mut self, packet: &[u8]) -> Option<ReassembledFrame> {
        if packet.len() <= 3 {
            return None;
        }
        let packet_id = u16::from_le_bytes([packet[0], packet[1]]);
        let frag_idx = packet[2];
        let payload = &packet[3..];

        if let Some(prev) = self.last_packet_id {
            if packet_id != prev.wrapping_add(1) {
                self.pending_discontinuous = true;
                // Only discard an incomplete multi-fragment frame; a single-packet
                // frame already finished before the gap should still flush with the gap flag.
                if frag_idx != 0 || self.expected_frag_idx > 1 {
                    self.pending_frame.clear();
                    self.corrupted_frame = frag_idx != 0;
                }
            }
        }
        self.last_packet_id = Some(packet_id);

        if frag_idx == 0 {
            let emitted = if !self.pending_frame.is_empty() && !self.corrupted_frame {
                Some(ReassembledFrame {
                    data: std::mem::take(&mut self.pending_frame),
                    discontinuous: std::mem::replace(&mut self.pending_discontinuous, false),
                })
            } else {
                self.pending_frame.clear();
                None
            };
            self.corrupted_frame = false;
            self.pending_frame.extend_from_slice(payload);
            self.expected_frag_idx = 1;
            emitted
        } else {
            if !self.corrupted_frame && frag_idx == self.expected_frag_idx {
                self.pending_frame.extend_from_slice(payload);
                self.expected_frag_idx = self.expected_frag_idx.saturating_add(1);
            } else {
                self.pending_frame.clear();
                self.corrupted_frame = true;
            }
            None
        }
    }

    pub fn flush(&mut self) -> Option<Vec<u8>> {
        if !self.pending_frame.is_empty() && !self.corrupted_frame {
            Some(std::mem::take(&mut self.pending_frame))
        } else {
            self.pending_frame.clear();
            None
        }
    }
}

/// Friend Pendant `95B = [LC3 30B * 3][5B footer]` 剥离器。
pub fn split_friend_pendant_lc3_frames(packet: &[u8]) -> Vec<&[u8]> {
    const FOOTER: usize = 5;
    const FRAME_LEN: usize = 30;
    if packet.len() <= FOOTER {
        return Vec::new();
    }
    let payload = &packet[..packet.len() - FOOTER];
    payload.chunks_exact(FRAME_LEN).collect()
}

pub enum OmiFrameDecoder {
    Opus(OpusLiveDecoder),
    Lc3(Lc3WorkBufs),
    Pcm16,
    Pcm8,
    MuLaw16,
    MuLaw8,
}

impl OmiFrameDecoder {
    pub fn for_codec(codec: OmiAudioCodec) -> Result<Self, SdkError> {
        match codec {
            OmiAudioCodec::Opus | OmiAudioCodec::OpusFs320 => {
                Ok(Self::Opus(OpusLiveDecoder::new_16k_mono()?))
            }
            OmiAudioCodec::Lc3Fs1030 => Ok(Self::Lc3(Lc3WorkBufs::new_16k_10ms_mono())),
            OmiAudioCodec::Pcm16 => Ok(Self::Pcm16),
            OmiAudioCodec::Pcm8 => Ok(Self::Pcm8),
            OmiAudioCodec::MuLaw16 => Ok(Self::MuLaw16),
            OmiAudioCodec::MuLaw8 => Ok(Self::MuLaw8),
        }
    }

    pub fn decode_frame(&mut self, frame: &[u8]) -> Result<Vec<i16>, SdkError> {
        match self {
            Self::Opus(dec) => dec.decode_packet(frame),
            Self::Lc3(work) => {
                let mut dec = work.decoder();
                decode_lc3_16k_10ms_frame(&mut dec, frame)
            }
            Self::Pcm16 => Ok(decode_pcm_le_to_16k_mono(frame, 16_000)),
            Self::Pcm8 => Ok(decode_pcm_le_to_16k_mono(frame, 8_000)),
            Self::MuLaw16 => Ok(decode_ulaw_to_16k_mono(frame, 16_000)),
            Self::MuLaw8 => Ok(decode_ulaw_to_16k_mono(frame, 8_000)),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RingBufferInfo {
    pub read_seq: u64,
    pub write_seq: u64,
    pub capacity_packets: u32,
    pub dropped_packets: u64,
    pub packet_size: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MultiFileEntry {
    pub index: u8,
    pub timestamp: u32,
    pub size_bytes: u32,
}

pub fn parse_ring_info(value: &[u8]) -> Option<RingBufferInfo> {
    if value.len() < 31 || value[0] != RING_NOTIFY_INFO {
        return None;
    }
    Some(RingBufferInfo {
        read_seq: u64::from_be_bytes(value[1..9].try_into().ok()?),
        write_seq: u64::from_be_bytes(value[9..17].try_into().ok()?),
        capacity_packets: u32::from_be_bytes(value[17..21].try_into().ok()?),
        dropped_packets: u64::from_be_bytes(value[21..29].try_into().ok()?),
        packet_size: u16::from_be_bytes(value[29..31].try_into().ok()?),
    })
}

pub fn parse_multi_file_list(value: &[u8]) -> Option<Vec<MultiFileEntry>> {
    if value.is_empty() {
        return None;
    }
    let count = usize::from(value[0]);
    if count == 0 && value.len() == 1 {
        return Some(Vec::new());
    }
    let expected = 1 + count * 8;
    if value.len() == expected && count <= 128 {
        let mut out = Vec::with_capacity(count);
        for idx in 0..count {
            let base = 1 + idx * 8;
            let timestamp = u32::from_be_bytes(value[base..base + 4].try_into().ok()?);
            let size_bytes = u32::from_be_bytes(value[base + 4..base + 8].try_into().ok()?);
            out.push(MultiFileEntry {
                index: idx as u8,
                timestamp,
                size_bytes,
            });
        }
        return Some(out);
    }
    None
}

/// 从 Omi FW 3.0.20+ Ring Buffer 原始字节流解包编码帧（每条 444B: `[ts:4 BE][packed len+frame]`）。
pub fn extract_ring_encoded_frames(raw: &[u8]) -> (Option<u32>, Vec<Vec<u8>>) {
    let mut first_ts = None;
    let mut frames = Vec::new();
    for record in raw.chunks_exact(RING_RECORD_SIZE) {
        let ts = u32::from_be_bytes([record[0], record[1], record[2], record[3]]);
        if first_ts.is_none() && ts > 1_700_000_000 {
            first_ts = Some(ts);
        }
        extract_len_prefixed_frames(&record[4..], &mut frames);
    }
    (first_ts, frames)
}

/// 解包 Legacy SD 卡存储块（支持 440B `[len:1][frame:len]...` 或 83B `[hdr3][len:1][frame]`）。
pub fn extract_len_prefixed_frames(payload: &[u8], out: &mut Vec<Vec<u8>>) {
    let mut off = 0usize;
    while off < payload.len() {
        let sz = usize::from(payload[off]);
        if sz == 0 {
            break;
        }
        if off + 1 + sz > payload.len() {
            break;
        }
        out.push(payload[off + 1..off + 1 + sz].to_vec());
        off += 1 + sz;
    }
}

/// 解码 Omi 按键手势。
///
/// Omi 量产版固件在 Zephyr GPIO 层写死长按约 3 秒直接硬件关机且无 BLE 配置开关，
/// 按压过程中也不会上报 <3s 的长按时长，因此彻底禁用长按（码 3 及释放 5 均返回 `None`），
/// 仅开放 `single_tap`（1）与 `double_tap`（2）。
pub fn decode_button_gesture(value: &[u8]) -> Option<&'static str> {
    let code = match value.len() {
        0 => return None,
        1..=3 => value[0],
        _ => u32::from_le_bytes([value[0], value[1], value[2], value[3]]) as u8,
    };
    match code {
        1 => Some("single_tap"),
        2 => Some("double_tap"),
        _ => None,
    }
}

pub fn matches_omi_name(trimmed: &str) -> bool {
    trimmed.eq_ignore_ascii_case("Omi")
        || trimmed.starts_with("Omi-")
        || trimmed.starts_with("Omi_")
        || trimmed.starts_with("Omi ")
        || trimmed.eq_ignore_ascii_case("Friend")
        || trimmed.starts_with("Friend_")
        || trimmed.starts_with("Friend ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reassembles_single_and_fragmented_omi_audio_packets_and_flags_gaps() {
        let mut r = OmiPacketReassembler::default();
        // Packet 0, frag 0
        assert!(r.push_packet(&[0, 0, 0, 1, 2, 3]).is_none());
        // Packet 1, frag 1 (continuation of frame 0)
        assert!(r.push_packet(&[1, 0, 1, 4, 5]).is_none());
        // Packet 2, frag 0 -> flushes frame 0 cleanly
        let f0 = r.push_packet(&[2, 0, 0, 9, 9]).unwrap();
        assert_eq!(f0.data, vec![1, 2, 3, 4, 5]);
        assert!(!f0.discontinuous);

        // Jump packet_id from 2 to 5 (lost 3 & 4)
        let f1 = r.push_packet(&[5, 0, 0, 7, 8]).unwrap();
        assert_eq!(f1.data, vec![9, 9]);
        assert!(f1.discontinuous);
        assert_eq!(r.flush(), Some(vec![7, 8]));
    }

    #[test]
    fn parses_ring_info_and_friend_pendant_footer() {
        let mut raw = vec![0u8; 31];
        raw[0] = RING_NOTIFY_INFO;
        raw[1..9].copy_from_slice(&10u64.to_be_bytes());
        raw[9..17].copy_from_slice(&15u64.to_be_bytes());
        raw[17..21].copy_from_slice(&1000u32.to_be_bytes());
        raw[21..29].copy_from_slice(&0u64.to_be_bytes());
        raw[29..31].copy_from_slice(&444u16.to_be_bytes());
        let info = parse_ring_info(&raw).unwrap();
        assert_eq!(info.read_seq, 10);
        assert_eq!(info.write_seq, 15);
        assert_eq!(info.packet_size, 444);

        let friend_pkt = vec![0xAAu8; 95];
        let lc3_frames = split_friend_pendant_lc3_frames(&friend_pkt);
        assert_eq!(lc3_frames.len(), 3);
        assert_eq!(lc3_frames[0].len(), 30);
    }

    #[test]
    fn parses_multi_file_list_and_packed_ring_record() {
        let mut buf = vec![2u8];
        buf.extend_from_slice(&1_730_000_000u32.to_be_bytes());
        buf.extend_from_slice(&4440u32.to_be_bytes());
        buf.extend_from_slice(&1_730_000_300u32.to_be_bytes());
        buf.extend_from_slice(&8880u32.to_be_bytes());
        let entries = parse_multi_file_list(&buf).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].size_bytes, 4440);
        assert_eq!(entries[1].timestamp, 1_730_000_300);

        let mut rec = vec![0u8; RING_RECORD_SIZE];
        rec[0..4].copy_from_slice(&1_730_000_000u32.to_be_bytes());
        rec[4] = 3;
        rec[5..8].copy_from_slice(&[11, 22, 33]);
        rec[8] = 2;
        rec[9..11].copy_from_slice(&[44, 55]);
        let (ts, frames) = extract_ring_encoded_frames(&rec);
        assert_eq!(ts, Some(1_730_000_000));
        assert_eq!(frames, vec![vec![11, 22, 33], vec![44, 55]]);

        assert_eq!(decode_button_gesture(&[1, 0, 0, 0]), Some("single_tap"));
        assert_eq!(decode_button_gesture(&[2, 0, 0, 0]), Some("double_tap"));
        assert_eq!(decode_button_gesture(&[3, 0, 0, 0]), None);
        assert_eq!(decode_button_gesture(&[5, 0, 0, 0]), None);
        assert_eq!(decode_button_gesture(&[]), None);
    }
}
