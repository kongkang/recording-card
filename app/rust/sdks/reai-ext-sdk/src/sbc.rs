// Bluetooth SIG A2DP SBC (8-subband) fixed-point decoder derived from FFmpeg's
// `libavcodec/sbcdec.c` / `sbcdec_data.h` / `sbc.c`:
//   Copyright (C) 2017  Aurelien Jacobs <aurel@gnuage.org>
//   Copyright (C) 2012-2013  Intel Corporation
//   Copyright (C) 2008-2010  Nokia Corporation
//   Copyright (C) 2004-2010  Marcel Holtmann <marcel@holtmann.org>
//   Copyright (C) 2004-2005  Henryk Ploetz <henryk@ploetzli.ch>
//   Copyright (C) 2005-2008  Brad Midgley <bmidgley@xmission.com>
//
// Rust translation:
//   Copyright (C) 2026  ReAI Team
//
// Licensed under the GNU Lesser General Public License, version 2.1 or later.

//! 纯 Rust Bluetooth A2DP SBC 解码器（支持 16kHz / 32kHz / 44.1kHz / 48kHz、
//! Mono / DualChannel / Stereo / JointStereo、Loudness / SNR、8-subband → 16kHz Mono PCM / WAV）。

#![allow(clippy::needless_range_loop)]

use std::path::Path;

use crate::audio::{resample_mono_to_16k, write_wav_16k_mono, AudioTranscodeReport};
use crate::types::SdkError;

pub const SBC_SYNC_WORD: u8 = 0x9C;
pub const MSBC_SYNC_WORD: u8 = 0xAD;
const MSBC_FRAME_SIZE: usize = 57;
const FIXED_EXTRA_BITS: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SbcChannelMode {
    Mono = 0,
    DualChannel = 1,
    Stereo = 2,
    JointStereo = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SbcFrameHeader {
    pub sample_rate: u32,
    pub freq_idx: usize,
    pub blocks: usize,
    pub mode: SbcChannelMode,
    pub channels: usize,
    pub alloc_snr: bool,
    pub subbands: usize,
    pub bitpool: u8,
    pub crc: u8,
    pub frame_len: usize,
    pub is_msbc: bool,
}

const SAMPLE_RATES: [u32; 4] = [16_000, 32_000, 44_100, 48_000];
const SBC_OFFSET8: [[i32; 8]; 4] = [
    [-2, 0, 0, 0, 0, 0, 0, 1],
    [-3, 0, 0, 0, 0, 0, 1, 2],
    [-4, 0, 0, 0, 0, 0, 1, 2],
    [-4, 0, 0, 0, 0, 0, 1, 2],
];

const SYNMATRIX8: [[i32; 8]; 16] = {
    let raw: [[u32; 8]; 16] = [
        [
            0x05a82798, 0xfa57d868, 0xfa57d868, 0x05a82798, 0x05a82798, 0xfa57d868, 0xfa57d868,
            0x05a82798,
        ],
        [
            0x0471ced0, 0xf8275a10, 0x018f8b84, 0x06a6d988, 0xf9592678, 0xfe70747c, 0x07d8a5f0,
            0xfb8e3130,
        ],
        [
            0x030fbc54, 0xf89be510, 0x07641af0, 0xfcf043ac, 0xfcf043ac, 0x07641af0, 0xf89be510,
            0x030fbc54,
        ],
        [
            0x018f8b84, 0xfb8e3130, 0x06a6d988, 0xf8275a10, 0x07d8a5f0, 0xf9592678, 0x0471ced0,
            0xfe70747c,
        ],
        [0; 8],
        [
            0xfe70747c, 0x0471ced0, 0xf9592678, 0x07d8a5f0, 0xf8275a10, 0x06a6d988, 0xfb8e3130,
            0x018f8b84,
        ],
        [
            0xfcf043ac, 0x07641af0, 0xf89be510, 0x030fbc54, 0x030fbc54, 0xf89be510, 0x07641af0,
            0xfcf043ac,
        ],
        [
            0xfb8e3130, 0x07d8a5f0, 0xfe70747c, 0xf9592678, 0x06a6d988, 0x018f8b84, 0xf8275a10,
            0x0471ced0,
        ],
        [
            0xfa57d868, 0x05a82798, 0x05a82798, 0xfa57d868, 0xfa57d868, 0x05a82798, 0x05a82798,
            0xfa57d868,
        ],
        [
            0xf9592678, 0x018f8b84, 0x07d8a5f0, 0x0471ced0, 0xfb8e3130, 0xf8275a10, 0xfe70747c,
            0x06a6d988,
        ],
        [
            0xf89be510, 0xfcf043ac, 0x030fbc54, 0x07641af0, 0x07641af0, 0x030fbc54, 0xfcf043ac,
            0xf89be510,
        ],
        [
            0xf8275a10, 0xf9592678, 0xfb8e3130, 0xfe70747c, 0x018f8b84, 0x0471ced0, 0x06a6d988,
            0x07d8a5f0,
        ],
        [0xf8000000; 8],
        [
            0xf8275a10, 0xf9592678, 0xfb8e3130, 0xfe70747c, 0x018f8b84, 0x0471ced0, 0x06a6d988,
            0x07d8a5f0,
        ],
        [
            0xf89be510, 0xfcf043ac, 0x030fbc54, 0x07641af0, 0x07641af0, 0x030fbc54, 0xfcf043ac,
            0xf89be510,
        ],
        [
            0xf9592678, 0x018f8b84, 0x07d8a5f0, 0x0471ced0, 0xfb8e3130, 0xf8275a10, 0xfe70747c,
            0x06a6d988,
        ],
    ];
    let mut table = [[0i32; 8]; 16];
    let mut i = 0;
    while i < 16 {
        let mut j = 0;
        while j < 8 {
            table[i][j] = (raw[i][j] as i32) >> 14;
            j += 1;
        }
        i += 1;
    }
    table
};

const PROTO_80M0: [i32; 40] = {
    let raw: [u32; 40] = [
        0x00000000, 0xfe8d1970, 0xee979f00, 0x11686100, 0x0172e690, 0xfff5bd1a, 0xfdf1c8d4,
        0xeac182c0, 0x0d9daee0, 0x00e530da, 0xffe9811d, 0xfd52986c, 0xe7054ca0, 0x0a00d410,
        0x006c1de4, 0xffdba705, 0xfcbc98e8, 0xe3889d20, 0x06af2308, 0x000bb7db, 0xffca00ed,
        0xfc3fbb68, 0xe071bc00, 0x03bf7948, 0xffc4e05c, 0xffb54b3b, 0xfbedadc0, 0xdde26200,
        0x0142291c, 0xff960e94, 0xff9f3e17, 0xfbd8f358, 0xdbf79400, 0xff405e01, 0xff7d4914,
        0xff8b1a31, 0xfc1417b8, 0xdac7bb40, 0xfdbb828c, 0xff762170,
    ];
    let mut table = [0i32; 40];
    let mut i = 0;
    while i < 40 {
        table[i] = (raw[i] as i32) >> 14;
        i += 1;
    }
    table
};

const PROTO_80M1: [i32; 40] = {
    let raw: [u32; 40] = [
        0xff7c272c, 0xfcb02620, 0xda612700, 0xfcb02620, 0xff7c272c, 0xff762170, 0xfdbb828c,
        0xdac7bb40, 0xfc1417b8, 0xff8b1a31, 0xff7d4914, 0xff405e01, 0xdbf79400, 0xfbd8f358,
        0xff9f3e17, 0xff960e94, 0x0142291c, 0xdde26200, 0xfbedadc0, 0xffb54b3b, 0xffc4e05c,
        0x03bf7948, 0xe071bc00, 0xfc3fbb68, 0xffca00ed, 0x000bb7db, 0x06af2308, 0xe3889d20,
        0xfcbc98e8, 0xffdba705, 0x006c1de4, 0x0a00d410, 0xe7054ca0, 0xfd52986c, 0xffe9811d,
        0x00e530da, 0x0d9daee0, 0xeac182c0, 0xfdf1c8d4, 0xfff5bd1a,
    ];
    let mut table = [0i32; 40];
    let mut i = 0;
    while i < 40 {
        table[i] = (raw[i] as i32) >> 14;
        i += 1;
    }
    table
};

struct BitReader<'a> {
    data: &'a [u8],
    byte_pos: usize,
    bit_pos: u8,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self {
            data,
            byte_pos: 0,
            bit_pos: 0,
        }
    }

    fn read(&mut self, bits: u8) -> Result<u16, SdkError> {
        if bits == 0 {
            return Ok(0);
        }
        let mut result = 0u32;
        let mut remaining = bits;
        while remaining > 0 {
            if self.byte_pos >= self.data.len() {
                return Err(SdkError::Protocol("SBC 比特流提前结束".into()));
            }
            let available = 8 - self.bit_pos;
            let take = remaining.min(available);
            let byte = u32::from(self.data[self.byte_pos]);
            let shift = available - take;
            let mask = (1u32 << take) - 1;
            result = (result << take) | ((byte >> shift) & mask);
            remaining -= take;
            self.bit_pos += take;
            if self.bit_pos >= 8 {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }
        Ok(result as u16)
    }
}

pub fn parse_frame_header(data: &[u8]) -> Result<SbcFrameHeader, SdkError> {
    if data.len() < 4 {
        return Err(SdkError::Protocol("SBC 帧头不足 4 字节".into()));
    }
    if data[0] == MSBC_SYNC_WORD {
        return Ok(SbcFrameHeader {
            sample_rate: 16_000,
            freq_idx: 0,
            blocks: 15,
            mode: SbcChannelMode::Mono,
            channels: 1,
            alloc_snr: false,
            subbands: 8,
            bitpool: 26,
            crc: data[3],
            frame_len: MSBC_FRAME_SIZE,
            is_msbc: true,
        });
    }
    if data[0] != SBC_SYNC_WORD {
        return Err(SdkError::Protocol(format!(
            "非法 SBC 同步字: 0x{:02x}",
            data[0]
        )));
    }
    let b1 = data[1];
    let freq_idx = usize::from((b1 >> 6) & 0x03);
    let sample_rate = SAMPLE_RATES[freq_idx];
    let blocks = [4usize, 8, 12, 16][usize::from((b1 >> 4) & 0x03)];
    let mode = match (b1 >> 2) & 0x03 {
        0 => SbcChannelMode::Mono,
        1 => SbcChannelMode::DualChannel,
        2 => SbcChannelMode::Stereo,
        _ => SbcChannelMode::JointStereo,
    };
    let channels = if mode == SbcChannelMode::Mono { 1 } else { 2 };
    let alloc_snr = ((b1 >> 1) & 0x01) != 0;
    let subbands = if (b1 & 0x01) != 0 { 8 } else { 4 };
    if subbands != 8 {
        return Err(SdkError::Unsupported(
            "暂不支持 4-subband SBC，仅支持标准 8-subband SBC".into(),
        ));
    }
    let bitpool = data[2];
    if bitpool < 2 {
        return Err(SdkError::Protocol(format!("非法 SBC bitpool={bitpool}")));
    }
    let joint_bits = if mode == SbcChannelMode::JointStereo {
        subbands
    } else {
        0
    };
    let payload_bits = match mode {
        SbcChannelMode::Mono | SbcChannelMode::DualChannel => {
            blocks * channels * usize::from(bitpool)
        }
        SbcChannelMode::Stereo | SbcChannelMode::JointStereo => {
            joint_bits + blocks * usize::from(bitpool)
        }
    };
    let frame_len = 4 + (4 * subbands * channels) / 8 + payload_bits.div_ceil(8);
    Ok(SbcFrameHeader {
        sample_rate,
        freq_idx,
        blocks,
        mode,
        channels,
        alloc_snr,
        subbands,
        bitpool,
        crc: data[3],
        frame_len,
        is_msbc: false,
    })
}

pub fn compute_header_crc(hdr: &SbcFrameHeader, frame: &[u8]) -> Result<u8, SdkError> {
    if frame.len() < 4 {
        return Err(SdkError::Protocol("SBC 帧过短无法计算 CRC".into()));
    }
    let total_bits =
        (if hdr.mode == SbcChannelMode::JointStereo {
            hdr.subbands
        } else {
            0
        }) + hdr.channels * hdr.subbands * 4;
    let need_bytes = 4 + total_bits.div_ceil(8);
    if frame.len() < need_bytes {
        return Err(SdkError::Protocol(format!(
            "SBC 帧长度 {} 小于头校验所需 {}",
            frame.len(),
            need_bytes
        )));
    }
    let mut crc = 0x0Fu8;
    for &byte in &[frame[1], frame[2]] {
        crc = crc8_step_byte(crc, byte);
    }
    let full_bytes = total_bits / 8;
    for &byte in &frame[4..4 + full_bytes] {
        crc = crc8_step_byte(crc, byte);
    }
    let rem_bits = total_bits % 8;
    if rem_bits > 0 {
        let last = frame[4 + full_bytes];
        for b in 0..rem_bits {
            let bit = ((crc >> 7) ^ ((last >> (7 - b)) & 1)) & 1;
            crc = (crc << 1) ^ if bit != 0 { 0x1D } else { 0 };
        }
    }
    Ok(crc)
}

#[inline]
fn crc8_step_byte(mut crc: u8, byte: u8) -> u8 {
    crc ^= byte;
    for _ in 0..8 {
        crc = if (crc & 0x80) != 0 {
            (crc << 1) ^ 0x1D
        } else {
            crc << 1
        };
    }
    crc
}

pub struct SbcDecoder {
    v: [[i32; 170]; 2],
    offset: [[i32; 16]; 2],
}

impl Default for SbcDecoder {
    fn default() -> Self {
        Self::new()
    }
}

impl SbcDecoder {
    pub fn new() -> Self {
        let mut offset = [[0i32; 16]; 2];
        for ch in 0..2 {
            for i in 0..16 {
                offset[ch][i] = 10 * i as i32 + 10;
            }
        }
        Self {
            v: [[0i32; 170]; 2],
            offset,
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// 解码单帧 SBC，返回 `(16kHz 单声道 i16 PCM, 消耗字节数)`。
    pub fn decode_frame(&mut self, input: &[u8]) -> Result<(Vec<i16>, usize), SdkError> {
        let hdr = parse_frame_header(input)?;
        if input.len() < hdr.frame_len {
            return Err(SdkError::Protocol(format!(
                "SBC 帧不完整: {} < {}",
                input.len(),
                hdr.frame_len
            )));
        }
        let frame = &input[..hdr.frame_len];
        let computed_crc = compute_header_crc(&hdr, frame)?;
        if computed_crc != hdr.crc {
            return Err(SdkError::Protocol(format!(
                "SBC 帧 CRC 校验失败: got 0x{:02x}, expected 0x{:02x}",
                computed_crc, hdr.crc
            )));
        }

        let mut reader = BitReader::new(&frame[4..]);
        let mut join = [0u8; 8];
        if hdr.mode == SbcChannelMode::JointStereo {
            for sb in 0..8 {
                join[sb] = reader.read(1)? as u8;
            }
        }

        let mut scale_factors = [[0u8; 8]; 2];
        for ch in 0..hdr.channels {
            for sb in 0..8 {
                scale_factors[ch][sb] = reader.read(4)? as u8;
            }
        }

        let mut bits = [[0u8; 8]; 2];
        let bitpool = i32::from(hdr.bitpool);
        match hdr.mode {
            SbcChannelMode::Mono | SbcChannelMode::DualChannel => {
                for ch in 0..hdr.channels {
                    bits[ch] = allocate_bits_single(
                        &scale_factors[ch],
                        hdr.freq_idx,
                        bitpool,
                        hdr.alloc_snr,
                    );
                }
            }
            SbcChannelMode::Stereo | SbcChannelMode::JointStereo => {
                bits = allocate_bits_stereo(
                    &scale_factors,
                    hdr.freq_idx,
                    bitpool,
                    hdr.alloc_snr,
                );
            }
        }

        let mut raw_pcm = Vec::with_capacity(hdr.blocks * 8);
        for _blk in 0..hdr.blocks {
            let mut subband = [[0i32; 8]; 2];
            for ch in 0..hdr.channels {
                for sb in 0..8 {
                    let b = bits[ch][sb];
                    if b == 0 {
                        continue;
                    }
                    let raw = i32::from(reader.read(b)?);
                    let shift = u32::from(scale_factors[ch][sb]) + 1 + FIXED_EXTRA_BITS;
                    let one = 1i32 << shift;
                    let levels = (1i32 << b) - 1;
                    if levels > 0 {
                        subband[ch][sb] = ((((raw << 1) | 1).wrapping_mul(one)) / levels) - one;
                    }
                }
            }

            if hdr.mode == SbcChannelMode::JointStereo {
                for sb in 0..7 {
                    if join[sb] != 0 {
                        let l = subband[0][sb].wrapping_add(subband[1][sb]);
                        let r = subband[0][sb].wrapping_sub(subband[1][sb]);
                        subband[0][sb] = l;
                        subband[1][sb] = r;
                    }
                }
            }

            if hdr.channels == 1 {
                let ch0 = self.synthesis_ch(0, &subband[0]);
                raw_pcm.extend_from_slice(&ch0);
            } else {
                let l = self.synthesis_ch(0, &subband[0]);
                let r = self.synthesis_ch(1, &subband[1]);
                for j in 0..8 {
                    let mixed = ((i32::from(l[j]) + i32::from(r[j])) / 2) as i16;
                    raw_pcm.push(mixed);
                }
            }
        }

        let out = resample_mono_to_16k(&raw_pcm, hdr.sample_rate);
        Ok((out, hdr.frame_len))
    }

    /// 连续解码整段 SBC 字节流，遇到偶发坏帧同步字节会尝试向后重同步下一帧（若全程零有效帧则返回错误）。
    pub fn decode_stream(&mut self, bytes: &[u8]) -> Result<Vec<i16>, SdkError> {
        if bytes.is_empty() {
            return Err(SdkError::Protocol("SBC 数据为空".into()));
        }
        let mut out = Vec::new();
        let mut pos = 0usize;
        let mut decoded_frames = 0usize;
        let mut last_err: Option<SdkError> = None;

        while pos + 4 <= bytes.len() {
            if bytes[pos] != SBC_SYNC_WORD && bytes[pos] != MSBC_SYNC_WORD {
                pos += 1;
                continue;
            }
            match self.decode_frame(&bytes[pos..]) {
                Ok((pcm, consumed)) => {
                    out.extend_from_slice(&pcm);
                    pos += consumed;
                    decoded_frames += 1;
                }
                Err(err) => {
                    last_err = Some(err);
                    pos += 1;
                }
            }
        }

        if decoded_frames == 0 {
            return Err(last_err.unwrap_or_else(|| SdkError::Protocol("未识别到有效 SBC 帧".into())));
        }
        Ok(out)
    }

    fn synthesis_ch(&mut self, ch: usize, s: &[i32; 8]) -> [i16; 8] {
        let v = &mut self.v[ch];
        let offset = &mut self.offset[ch];

        for i in 0..16 {
            offset[i] -= 1;
            if offset[i] < 0 {
                offset[i] = 159;
                let (left, right) = v.split_at_mut(160);
                right[0..9].copy_from_slice(&left[0..9]);
            }

            let row = &SYNMATRIX8[i];
            let acc = (row[0] as u32)
                .wrapping_mul(s[0] as u32)
                .wrapping_add((row[1] as u32).wrapping_mul(s[1] as u32))
                .wrapping_add((row[2] as u32).wrapping_mul(s[2] as u32))
                .wrapping_add((row[3] as u32).wrapping_mul(s[3] as u32))
                .wrapping_add((row[4] as u32).wrapping_mul(s[4] as u32))
                .wrapping_add((row[5] as u32).wrapping_mul(s[5] as u32))
                .wrapping_add((row[6] as u32).wrapping_mul(s[6] as u32))
                .wrapping_add((row[7] as u32).wrapping_mul(s[7] as u32));

            v[offset[i] as usize] = (acc as i32) >> 15;
        }

        let mut output = [0i16; 8];
        let mut idx = 0usize;
        for i in 0..8 {
            let k = (i + 8) & 0xF;
            let oi = offset[i] as usize;
            let ok = offset[k] as usize;

            let acc = (v[oi] as u32)
                .wrapping_mul(PROTO_80M0[idx] as u32)
                .wrapping_add(v[ok + 1].wrapping_mul(PROTO_80M1[idx]) as u32)
                .wrapping_add(v[oi + 2].wrapping_mul(PROTO_80M0[idx + 1]) as u32)
                .wrapping_add(v[ok + 3].wrapping_mul(PROTO_80M1[idx + 1]) as u32)
                .wrapping_add(v[oi + 4].wrapping_mul(PROTO_80M0[idx + 2]) as u32)
                .wrapping_add(v[ok + 5].wrapping_mul(PROTO_80M1[idx + 2]) as u32)
                .wrapping_add(v[oi + 6].wrapping_mul(PROTO_80M0[idx + 3]) as u32)
                .wrapping_add(v[ok + 7].wrapping_mul(PROTO_80M1[idx + 3]) as u32)
                .wrapping_add(v[oi + 8].wrapping_mul(PROTO_80M0[idx + 4]) as u32)
                .wrapping_add(v[ok + 9].wrapping_mul(PROTO_80M1[idx + 4]) as u32);

            output[i] = ((acc as i32) >> 15).clamp(-32768, 32767) as i16;
            idx += 5;
        }
        output
    }
}

fn bitneed_of(sf: u8, freq_idx: usize, sb: usize, alloc_snr: bool) -> i32 {
    let sf_i = i32::from(sf);
    if alloc_snr {
        sf_i
    } else if sf_i == 0 {
        -5
    } else {
        let loudness = sf_i - SBC_OFFSET8[freq_idx][sb];
        if loudness > 0 {
            loudness / 2
        } else {
            loudness
        }
    }
}

fn allocate_bits_single(scale_factors: &[u8; 8], freq_idx: usize, bitpool: i32, alloc_snr: bool) -> [u8; 8] {
    let mut bitneed = [0i32; 8];
    let mut max_bitneed = 0i32;
    for sb in 0..8 {
        bitneed[sb] = bitneed_of(scale_factors[sb], freq_idx, sb, alloc_snr);
        if bitneed[sb] > max_bitneed {
            max_bitneed = bitneed[sb];
        }
    }

    let mut bitcount = 0i32;
    let mut slicecount = 0i32;
    let mut bitslice = max_bitneed + 1;

    loop {
        bitslice -= 1;
        bitcount += slicecount;
        slicecount = 0;
        for sb in 0..8 {
            let n = bitneed[sb];
            if n > bitslice + 1 && n < bitslice + 16 {
                slicecount += 1;
            } else if n == bitslice + 1 {
                slicecount += 2;
            }
        }
        if bitcount + slicecount >= bitpool {
            break;
        }
    }

    if bitcount + slicecount == bitpool {
        bitcount += slicecount;
        bitslice -= 1;
    }

    let mut bits = [0u8; 8];
    for sb in 0..8 {
        bits[sb] = if bitneed[sb] < bitslice + 2 {
            0
        } else {
            (bitneed[sb] - bitslice).min(16) as u8
        };
    }

    for sb in 0..8 {
        if bitcount >= bitpool {
            break;
        }
        if bits[sb] >= 2 && bits[sb] < 16 {
            bits[sb] += 1;
            bitcount += 1;
        } else if bitneed[sb] == bitslice + 1 && bitpool > bitcount + 1 {
            bits[sb] = 2;
            bitcount += 2;
        }
    }

    for sb in 0..8 {
        if bitcount >= bitpool {
            break;
        }
        if bits[sb] < 16 {
            bits[sb] += 1;
            bitcount += 1;
        }
    }

    bits
}

fn allocate_bits_stereo(
    scale_factors: &[[u8; 8]; 2],
    freq_idx: usize,
    bitpool: i32,
    alloc_snr: bool,
) -> [[u8; 8]; 2] {
    let mut bitneed = [[0i32; 8]; 2];
    let mut max_bitneed = 0i32;
    for ch in 0..2 {
        for sb in 0..8 {
            bitneed[ch][sb] = bitneed_of(scale_factors[ch][sb], freq_idx, sb, alloc_snr);
            if bitneed[ch][sb] > max_bitneed {
                max_bitneed = bitneed[ch][sb];
            }
        }
    }

    let mut bitcount = 0i32;
    let mut slicecount = 0i32;
    let mut bitslice = max_bitneed + 1;

    loop {
        bitslice -= 1;
        bitcount += slicecount;
        slicecount = 0;
        for ch in 0..2 {
            for sb in 0..8 {
                let n = bitneed[ch][sb];
                if n > bitslice + 1 && n < bitslice + 16 {
                    slicecount += 1;
                } else if n == bitslice + 1 {
                    slicecount += 2;
                }
            }
        }
        if bitcount + slicecount >= bitpool {
            break;
        }
    }

    if bitcount + slicecount == bitpool {
        bitcount += slicecount;
        bitslice -= 1;
    }

    let mut bits = [[0u8; 8]; 2];
    for ch in 0..2 {
        for sb in 0..8 {
            bits[ch][sb] = if bitneed[ch][sb] < bitslice + 2 {
                0
            } else {
                (bitneed[ch][sb] - bitslice).min(16) as u8
            };
        }
    }

    for sb in 0..8 {
        for ch in 0..2 {
            if bitcount >= bitpool {
                break;
            }
            if bits[ch][sb] >= 2 && bits[ch][sb] < 16 {
                bits[ch][sb] += 1;
                bitcount += 1;
            } else if bitneed[ch][sb] == bitslice + 1 && bitpool > bitcount + 1 {
                bits[ch][sb] = 2;
                bitcount += 2;
            }
        }
    }

    for sb in 0..8 {
        for ch in 0..2 {
            if bitcount >= bitpool {
                break;
            }
            if bits[ch][sb] < 16 {
                bits[ch][sb] += 1;
                bitcount += 1;
            }
        }
    }

    bits
}

pub fn sbc_bytes_to_16k_mono(sbc_bytes: &[u8]) -> Result<Vec<i16>, SdkError> {
    let mut dec = SbcDecoder::new();
    dec.decode_stream(sbc_bytes)
}

pub fn sbc_bytes_to_wav_file_16k_mono(
    sbc_bytes: &[u8],
    output: &Path,
) -> Result<AudioTranscodeReport, SdkError> {
    let pcm = sbc_bytes_to_16k_mono(sbc_bytes)?;
    write_wav_16k_mono(output, &pcm)
}

pub fn sbc_to_wav_16k_mono(
    input: &Path,
    output: &Path,
) -> Result<AudioTranscodeReport, SdkError> {
    let bytes = std::fs::read(input)?;
    sbc_bytes_to_wav_file_16k_mono(&bytes, output)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Real 128-byte A2DP SBC frames captured from 讯飞智能录音笔 A1 (`live_tts.sbc`,
    // 16kHz / 16 blocks / DualChannel / Loudness / 8 subbands / bitpool=29).
    const REAL_A1_SBC_FRAME_0: [u8; 128] = [
        0x9c, 0x35, 0x1d, 0x13, 0x64, 0x32, 0x22, 0x32, 0x64, 0x43, 0x22, 0x22, 0x80, 0xd7, 0x15,
        0x6c, 0x57, 0x84, 0x94, 0x61, 0xa9, 0xb6, 0x5b, 0x19, 0x1a, 0x24, 0x55, 0xd4, 0x8d, 0xc6,
        0x32, 0xa7, 0x6d, 0xb5, 0xe3, 0xac, 0x49, 0xae, 0x5e, 0x1b, 0x50, 0x81, 0x66, 0xdd, 0x63,
        0xaa, 0x79, 0x74, 0x5a, 0xac, 0xeb, 0x12, 0xd5, 0x15, 0xa8, 0x93, 0x8c, 0x8e, 0xd8, 0x9e,
        0x5b, 0x59, 0x49, 0xa4, 0xe3, 0x8a, 0x2e, 0x29, 0x9d, 0x35, 0xbb, 0x58, 0xea, 0x6d, 0xab,
        0x97, 0x14, 0x6d, 0x3a, 0x19, 0x5b, 0x6e, 0x69, 0x58, 0xd8, 0xf4, 0x51, 0x16, 0xca, 0x95,
        0x4e, 0x36, 0x6c, 0x21, 0x92, 0xb2, 0xa2, 0x1c, 0x8d, 0xa0, 0x87, 0x93, 0x54, 0x92, 0x6a,
        0x53, 0x28, 0x91, 0x28, 0x9b, 0x39, 0x20, 0xa8, 0x98, 0x33, 0x79, 0x16, 0xc5, 0x86, 0x85,
        0x15, 0xde, 0x4e, 0x92, 0x2d, 0xec, 0xe9, 0xc9,
    ];
    const REAL_A1_SBC_FRAME_200: [u8; 128] = [
        0x9c, 0x35, 0x1d, 0xeb, 0x66, 0x54, 0x66, 0x64, 0x66, 0x55, 0x56, 0x64, 0x8b, 0xa0, 0xec,
        0xcc, 0x4a, 0x93, 0x88, 0x22, 0xe8, 0xcc, 0xb3, 0x3b, 0x97, 0x1f, 0x2a, 0x44, 0xd3, 0x26,
        0xdf, 0x09, 0xa3, 0xa1, 0xf2, 0xf4, 0x2c, 0x51, 0xc2, 0x72, 0xd5, 0x9b, 0xa2, 0xb7, 0x8c,
        0xb0, 0x9c, 0x44, 0x66, 0xcc, 0x85, 0x33, 0x3b, 0x3a, 0xda, 0xd0, 0x3b, 0x72, 0x4d, 0x13,
        0x0e, 0x49, 0x8a, 0x2e, 0xca, 0x1d, 0x94, 0xb2, 0x25, 0x8d, 0x1a, 0xb1, 0x0c, 0xd1, 0x86,
        0xd3, 0x87, 0x56, 0xe6, 0xbb, 0x80, 0xbb, 0x12, 0x56, 0xdc, 0x4a, 0x8e, 0xef, 0x61, 0x50,
        0x49, 0x85, 0x44, 0xdd, 0x24, 0x8b, 0x12, 0x76, 0x55, 0x5b, 0x99, 0x12, 0xd3, 0x6c, 0x63,
        0x57, 0x63, 0x0e, 0x3a, 0xb3, 0x0c, 0xc8, 0x6a, 0x03, 0x4c, 0x46, 0x6e, 0x9d, 0x36, 0x28,
        0x66, 0xf8, 0x83, 0x2b, 0xb6, 0xdb, 0x6d, 0x11,
    ];

    #[test]
    fn decodes_real_a1_sbc_frames_and_writes_16k_mono_wav() {
        let mut dec = SbcDecoder::new();
        let (s0, len0) = dec.decode_frame(&REAL_A1_SBC_FRAME_0).unwrap();
        assert_eq!(len0, 128);
        assert_eq!(s0.len(), 128);

        let (s200, len200) = dec.decode_frame(&REAL_A1_SBC_FRAME_200).unwrap();
        assert_eq!(len200, 128);
        assert_eq!(s200.len(), 128);
        let peak = s200.iter().map(|v| v.abs()).max().unwrap_or(0);
        assert!(peak > 50, "expected non-silent decoded energy, peak={peak}");

        // Reject corrupt CRC
        let mut bad = REAL_A1_SBC_FRAME_0;
        bad[3] ^= 0xFF;
        assert!(SbcDecoder::new().decode_frame(&bad).is_err());

        let temp_dir =
            std::env::temp_dir().join(format!("reai_ext_sbc_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(&temp_dir).unwrap();
        let wav_path = temp_dir.join("out.wav");

        let mut stream = Vec::new();
        stream.extend_from_slice(&REAL_A1_SBC_FRAME_0);
        stream.extend_from_slice(&REAL_A1_SBC_FRAME_200);
        let report = sbc_bytes_to_wav_file_16k_mono(&stream, &wav_path).unwrap();
        assert_eq!(report.sample_rate, 16_000);
        assert_eq!(report.channels, 1);
        assert_eq!(report.samples, 256);

        let wav = std::fs::read(&wav_path).unwrap();
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(wav.len(), 44 + 256 * 2);

        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn decodes_extreme_dc_allocations_matching_ffmpeg() {
        let sf13 = [13u8, 0, 0, 0, 0, 0, 0, 0];
        assert_eq!(
            allocate_bits_single(&sf13, 0, 28, false),
            [14, 2, 2, 2, 2, 2, 2, 2]
        );
        let sf6 = [6u8, 0, 0, 0, 0, 0, 0, 0];
        assert_eq!(
            allocate_bits_single(&sf6, 0, 28, false),
            [12, 3, 3, 2, 2, 2, 2, 2]
        );

        // Real FFmpeg frame for amp=100 DC steady state (sf=[6,0..], alloc=[12,3,3,2,2,2,2,2]).
        let amp100_frame: [u8; 64] = [
            0x9c, 0x31, 0x1c, 0x4d, 0x60, 0x00, 0x00, 0x00, 0xe4, 0x07, 0x15, 0x5e, 0x40, 0x71,
            0x55, 0xe4, 0x07, 0x15, 0x5e, 0x40, 0x71, 0x55, 0xe4, 0x07, 0x15, 0x5e, 0x40, 0x71,
            0x55, 0xe4, 0x07, 0x15, 0x5e, 0x40, 0x71, 0x55, 0xe4, 0x07, 0x15, 0x5e, 0x40, 0x71,
            0x55, 0xe4, 0x07, 0x15, 0x5e, 0x40, 0x71, 0x55, 0xe4, 0x07, 0x15, 0x5e, 0x40, 0x71,
            0x55, 0xe4, 0x07, 0x15, 0x5e, 0x40, 0x71, 0x55,
        ];
        let mut dec = SbcDecoder::new();
        // Warm filterbank over several frames to reach DC steady state ~ +100.
        let mut stream = Vec::with_capacity(64 * 8);
        for _ in 0..8 {
            stream.extend_from_slice(&amp100_frame);
        }
        let pcm = dec.decode_stream(&stream).unwrap();
        let tail = &pcm[pcm.len() - 64..];
        assert!(
            tail.iter().all(|&s| (s - 100).abs() <= 4),
            "expected steady DC ~100, got {:?}",
            &tail[..16]
        );
    }
}
