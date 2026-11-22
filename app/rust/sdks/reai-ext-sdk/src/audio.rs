use std::fs::File;
use std::io::{BufReader, BufWriter, Write};
use std::path::Path;

use lc3_codec::common::complex::{Complex, Scaler};
use lc3_codec::common::config::{FrameDuration, SamplingFrequency};
use lc3_codec::decoder::lc3_decoder::Lc3Decoder;
use opus_pure::{OggOpusReader, OpusDecoder, Trim, MAX_PACKET_SAMPLES};

use crate::types::SdkError;

#[derive(Debug, Clone, Copy)]
pub struct AudioTranscodeReport {
    pub sample_rate: u32,
    pub channels: u16,
    pub samples: usize,
    pub duration_secs: f64,
}

/// 写入标准 16kHz / 16-bit LE / 单声道 RIFF WAV 文件。
pub fn write_wav_16k_mono(output: &Path, samples: &[i16]) -> Result<AudioTranscodeReport, SdkError> {
    if let Some(parent) = output.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let sample_rate: u32 = 16_000;
    let channels: u16 = 1;
    let bits_per_sample: u16 = 16;
    let byte_rate: u32 = sample_rate * u32::from(channels) * u32::from(bits_per_sample) / 8;
    let block_align: u16 = channels * bits_per_sample / 8;
    let data_bytes = (samples.len() as u64)
        .checked_mul(2)
        .and_then(|v| u32::try_from(v).ok())
        .ok_or_else(|| SdkError::Io("WAV 大小超过 4GB 限制".into()))?;
    let riff_size = data_bytes.saturating_add(36);

    let file = File::create(output)?;
    let mut writer = BufWriter::new(file);
    writer.write_all(b"RIFF")?;
    writer.write_all(&riff_size.to_le_bytes())?;
    writer.write_all(b"WAVE")?;
    writer.write_all(b"fmt ")?;
    writer.write_all(&16u32.to_le_bytes())?;
    writer.write_all(&1u16.to_le_bytes())?; // PCM
    writer.write_all(&channels.to_le_bytes())?;
    writer.write_all(&sample_rate.to_le_bytes())?;
    writer.write_all(&byte_rate.to_le_bytes())?;
    writer.write_all(&block_align.to_le_bytes())?;
    writer.write_all(&bits_per_sample.to_le_bytes())?;
    writer.write_all(b"data")?;
    writer.write_all(&data_bytes.to_le_bytes())?;
    for &sample in samples {
        writer.write_all(&sample.to_le_bytes())?;
    }
    writer.flush()?;

    Ok(AudioTranscodeReport {
        sample_rate,
        channels,
        samples: samples.len(),
        duration_secs: samples.len() as f64 / f64::from(sample_rate),
    })
}

/// 纯 Rust 将 Ogg Opus (`.ogg` / `.opus`) 解码为 16kHz 单声道 WAV。
pub fn ogg_opus_to_wav_16k_mono(
    input: &Path,
    output: &Path,
) -> Result<AudioTranscodeReport, SdkError> {
    let file = File::open(input)?;
    let mut reader = OggOpusReader::new(BufReader::new(file))
        .map_err(|e| SdkError::Protocol(format!("打开 Ogg Opus 失败: {e}")))?;
    let head = reader.head().clone();
    let channels = usize::from(head.channel_count.max(1));
    let mut decoder = head
        .decoder(16_000)
        .map_err(|e| SdkError::Protocol(format!("初始化 Opus 解码器失败: {e}")))?;
    let mut trim = Trim::new(&head, 16_000, channels)
        .map_err(|e| SdkError::Protocol(format!("初始化 Opus Trim 失败: {e}")))?;

    let mut block = vec![0.0f32; MAX_PACKET_SAMPLES * channels];
    let mut mono_i16 = Vec::new();
    for packet_res in reader.packets() {
        let packet = packet_res
            .map_err(|e| SdkError::Protocol(format!("读取 Ogg 数据包失败: {e}")))?;
        let n = decoder
            .decode(&packet.data, MAX_PACKET_SAMPLES, &mut block)
            .map_err(|e| SdkError::Protocol(format!("Opus 解码失败: {e}")))?;
        let kept = trim.keep(&packet, &block[..n * channels]);
        for frame in kept.chunks_exact(channels) {
            let sum: f32 = frame.iter().copied().sum();
            let avg = (sum / channels as f32).clamp(-1.0, 1.0);
            let sample = (avg * 32767.0).round().clamp(-32768.0, 32767.0) as i16;
            mono_i16.push(sample);
        }
    }

    write_wav_16k_mono(output, &mono_i16)
}

/// 将设备端写入的 `.wav`（例如 Omi 离线下载生成的 WAV）标准化为 16kHz 单声道 WAV，并返回准确采样与时长。
pub fn wav_to_16k_mono(input: &Path, output: &Path) -> Result<AudioTranscodeReport, SdkError> {
    let bytes = std::fs::read(input)?;
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(SdkError::Protocol("非法的 RIFF/WAVE 文件".into()));
    }

    let mut pos = 12usize;
    let mut sample_rate = 16_000u32;
    let mut channels = 1u16;
    let mut bits_per_sample = 16u16;
    let mut pcm_bytes: Option<&[u8]> = None;

    while pos + 8 <= bytes.len() {
        let chunk_id = &bytes[pos..pos + 4];
        let chunk_len = u32::from_le_bytes([
            bytes[pos + 4],
            bytes[pos + 5],
            bytes[pos + 6],
            bytes[pos + 7],
        ]) as usize;
        let payload_start = pos + 8;
        let mut payload_end = payload_start.saturating_add(chunk_len).min(bytes.len());
        if chunk_id == b"data" && (chunk_len == 0 || payload_end < bytes.len()) {
            let next_is_chunk = payload_end + 8 <= bytes.len()
                && bytes[payload_end..payload_end + 4]
                    .iter()
                    .all(|b| b.is_ascii_alphanumeric() || *b == b' ');
            if chunk_len == 0 || !next_is_chunk {
                payload_end = bytes.len();
            }
        }
        if chunk_id == b"fmt " && payload_end - payload_start >= 16 {
            let fmt = &bytes[payload_start..payload_end];
            let audio_format = u16::from_le_bytes([fmt[0], fmt[1]]);
            if audio_format != 1 {
                return Err(SdkError::Protocol(format!(
                    "不支持的 WAV 编码格式: {audio_format}"
                )));
            }
            channels = u16::from_le_bytes([fmt[2], fmt[3]]).max(1);
            sample_rate = u32::from_le_bytes([fmt[4], fmt[5], fmt[6], fmt[7]]).max(8_000);
            bits_per_sample = u16::from_le_bytes([fmt[14], fmt[15]]);
        } else if chunk_id == b"data" {
            pcm_bytes = Some(&bytes[payload_start..payload_end]);
        }
        let step = chunk_len + (chunk_len % 2);
        pos = payload_start.saturating_add(step);
    }

    let data = pcm_bytes.ok_or_else(|| SdkError::Protocol("WAV 缺少 data 块".into()))?;
    if bits_per_sample != 16 {
        return Err(SdkError::Protocol(format!(
            "仅支持 16-bit PCM WAV，收到 {bits_per_sample}-bit"
        )));
    }
    let ch = usize::from(channels);
    let mut mono = Vec::with_capacity(data.len() / (2 * ch));
    for frame in data.chunks_exact(2 * ch) {
        let mut acc: i32 = 0;
        for c in 0..ch {
            let s = i16::from_le_bytes([frame[c * 2], frame[c * 2 + 1]]);
            acc += i32::from(s);
        }
        mono.push((acc / ch as i32) as i16);
    }
    let resampled = resample_mono_to_16k(&mono, sample_rate);
    write_wav_16k_mono(output, &resampled)
}

/// 简单线性插值重采样到 16kHz（满足 8kHz -> 16kHz、24kHz/48kHz 整数倍降采样/升采样）。
pub fn resample_mono_to_16k(samples: &[i16], input_rate: u32) -> Vec<i16> {
    if input_rate == 16_000 || samples.is_empty() {
        return samples.to_vec();
    }
    if input_rate == 8_000 {
        let mut out = Vec::with_capacity(samples.len() * 2);
        for (idx, &cur) in samples.iter().enumerate() {
            let next = samples.get(idx + 1).copied().unwrap_or(cur);
            let mid = ((i32::from(cur) + i32::from(next)) / 2) as i16;
            out.push(cur);
            out.push(mid);
        }
        return out;
    }
    let out_len = ((samples.len() as u64) * 16_000 / u64::from(input_rate.max(1))) as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let pos = (i as f64) * f64::from(input_rate) / 16_000.0;
        let idx = (pos.floor() as usize).min(samples.len() - 1);
        let frac = pos - (idx as f64);
        let a = f64::from(samples[idx]);
        let b = f64::from(samples.get(idx + 1).copied().unwrap_or(samples[idx]));
        let val = (a + (b - a) * frac).round().clamp(-32768.0, 32767.0) as i16;
        out.push(val);
    }
    out
}

/// 有状态实时裸 Opus 帧解码器（直接输出 16kHz 单声道 i16 PCM）。
pub struct OpusLiveDecoder {
    decoder: OpusDecoder,
    scratch: Vec<i16>,
}

impl OpusLiveDecoder {
    pub fn new_16k_mono() -> Result<Self, SdkError> {
        let decoder = OpusDecoder::new(16_000, 1)
            .map_err(|e| SdkError::Protocol(format!("创建实时 Opus 解码器失败: {e}")))?;
        Ok(Self {
            decoder,
            scratch: vec![0i16; MAX_PACKET_SAMPLES],
        })
    }

    pub fn decode_packet(&mut self, packet: &[u8]) -> Result<Vec<i16>, SdkError> {
        if packet.is_empty() {
            return Ok(Vec::new());
        }
        let n = self
            .decoder
            .decode_s16(packet, MAX_PACKET_SAMPLES, &mut self.scratch)
            .map_err(|e| SdkError::Protocol(format!("实时 Opus 帧解码失败: {e}")))?;
        Ok(self.scratch[..n].to_vec())
    }
}

/// G.711 u-law 字节解码为 i16（ITU-T G.711 标准表计算）。
pub fn decode_ulaw_byte(u_val: u8) -> i16 {
    let u = !u_val;
    let sign = u & 0x80;
    let exponent = (u >> 4) & 0x07;
    let mantissa = u & 0x0F;
    let sample = (((i32::from(mantissa) << 3) + 0x84) << exponent) - 0x84;
    if sign != 0 {
        -(sample as i16)
    } else {
        sample as i16
    }
}

/// 解码 u-law 字节流并升采样/输出为 16kHz 单声道 i16。
pub fn decode_ulaw_to_16k_mono(bytes: &[u8], input_rate: u32) -> Vec<i16> {
    let raw: Vec<i16> = bytes.iter().copied().map(decode_ulaw_byte).collect();
    resample_mono_to_16k(&raw, input_rate)
}

/// 解码小端 i16 PCM 字节流并升采样/输出为 16kHz 单声道 i16。
pub fn decode_pcm_le_to_16k_mono(bytes: &[u8], input_rate: u32) -> Vec<i16> {
    let mut raw = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        raw.push(i16::from_le_bytes([pair[0], pair[1]]));
    }
    resample_mono_to_16k(&raw, input_rate)
}

/// LC3 16kHz 10ms（每帧 30 字节）纯 Rust 解码工作区。
pub struct Lc3WorkBufs {
    scaler: Vec<Scaler>,
    complex: Vec<Complex>,
}

impl Lc3WorkBufs {
    pub fn new_16k_10ms_mono() -> Self {
        let (scaler_len, complex_len) = Lc3Decoder::calc_working_buffer_lengths(
            1,
            FrameDuration::TenMs,
            SamplingFrequency::Hz16000,
        );
        Self {
            scaler: vec![0.0; scaler_len],
            complex: vec![Complex::default(); complex_len],
        }
    }

    pub fn decoder(&mut self) -> Lc3Decoder<'_> {
        Lc3Decoder::new(
            1,
            FrameDuration::TenMs,
            SamplingFrequency::Hz16000,
            &mut self.scaler,
            &mut self.complex,
        )
    }
}

pub fn decode_lc3_16k_10ms_frame(
    decoder: &mut Lc3Decoder<'_>,
    frame_bytes: &[u8],
) -> Result<Vec<i16>, SdkError> {
    if frame_bytes.is_empty() {
        return Ok(Vec::new());
    }
    let mut out = vec![0i16; 160]; // 16000 Hz * 10ms = 160 samples
    decoder
        .decode_frame(16, 0, frame_bytes, &mut out)
        .map_err(|e| SdkError::Protocol(format!("LC3 帧解码失败: {e:?}")))?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use opus_pure::{Application, OggOpusWriter, OpusEncoder, OpusHead, MAX_PACKET_BYTES};
    use std::f32::consts::PI;

    #[test]
    fn roundtrip_ogg_opus_to_16k_wav() {
        let temp_dir =
            std::env::temp_dir().join(format!("reai_ext_sdk_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(&temp_dir).unwrap();
        let ogg_path = temp_dir.join("sample.ogg");
        let wav_path = temp_dir.join("sample.wav");

        // Encode 0.5s 440Hz sine @ 16kHz mono into Ogg Opus
        let rate = 16_000i32;
        let frame = 320usize; // 20ms @ 16kHz
        let total_samples = 8_000usize; // 0.5s
        let mut pcm = Vec::with_capacity(total_samples);
        for i in 0..total_samples {
            pcm.push((2.0 * PI * 440.0 * (i as f32) / rate as f32).sin() * 0.5);
        }

        let mut encoder = OpusEncoder::new(rate, 1, Application::Voip).unwrap();
        let head = OpusHead::for_encoder(&encoder, rate as u32);
        let ticks = 48_000 / rate as usize;
        let total_frames = (total_samples + (head.pre_skip as usize).div_ceil(ticks)).div_ceil(frame);
        let final_granule = u64::from(head.pre_skip) + (total_samples * ticks) as u64;

        {
            let f = File::create(&ogg_path).unwrap();
            let mut writer = OggOpusWriter::new(BufWriter::new(f), head).unwrap();
            let mut pkt = vec![0u8; MAX_PACKET_BYTES];
            let mut block = vec![0.0f32; frame];
            for i in 0..total_frames {
                let start = (i * frame).min(pcm.len());
                let end = (start + frame).min(pcm.len());
                block[..end - start].copy_from_slice(&pcm[start..end]);
                block[end - start..].fill(0.0);
                let n = encoder.encode(&block, frame, &mut pkt).unwrap();
                if i + 1 == total_frames {
                    let dur = final_granule - writer.granule() as u64;
                    writer.write_packet_with_duration(&pkt[..n], dur as u32).unwrap();
                } else {
                    writer.write_packet(&pkt[..n]).unwrap();
                }
            }
            writer.finish().unwrap();
        }

        let report = ogg_opus_to_wav_16k_mono(&ogg_path, &wav_path).unwrap();
        assert_eq!(report.sample_rate, 16_000);
        assert_eq!(report.channels, 1);
        assert!((report.duration_secs - 0.5).abs() < 0.05);
        assert!(report.samples > 7_000);

        let wav_bytes = std::fs::read(&wav_path).unwrap();
        assert_eq!(&wav_bytes[0..4], b"RIFF");
        assert_eq!(&wav_bytes[8..12], b"WAVE");

        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn live_opus_and_lc3_decoders_initialize_and_decode_valid_frames() {
        let mut enc = OpusEncoder::new(16_000, 1, Application::Voip).unwrap();
        let pcm = vec![1200i16; 320];
        let mut pkt = vec![0u8; MAX_PACKET_BYTES];
        let n = enc.encode_s16(&pcm, 320, &mut pkt).unwrap();
        let mut dec = OpusLiveDecoder::new_16k_mono().unwrap();
        let out = dec.decode_packet(&pkt[..n]).unwrap();
        assert_eq!(out.len(), 320);

        let mut lc3_work = Lc3WorkBufs::new_16k_10ms_mono();
        let _lc3_dec = lc3_work.decoder();
    }

    #[test]
    fn wav_to_16k_mono_recovers_undersized_data_chunk_header() {
        let temp_dir =
            std::env::temp_dir().join(format!("reai_ext_wav_fix_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(&temp_dir).unwrap();
        let raw_path = temp_dir.join("undersized.wav");
        let fixed_path = temp_dir.join("fixed.wav");

        let samples = vec![1234i16; 320];
        write_wav_16k_mono(&raw_path, &samples).unwrap();
        let mut bytes = std::fs::read(&raw_path).unwrap();
        // Simulate A1 USB WAV quirk: RIFF and data chunk sizes stamped as 0 while PCM follows.
        bytes[4..8].copy_from_slice(&0u32.to_le_bytes());
        bytes[40..44].copy_from_slice(&0u32.to_le_bytes());
        std::fs::write(&raw_path, &bytes).unwrap();

        let report = wav_to_16k_mono(&raw_path, &fixed_path).unwrap();
        assert_eq!(report.samples, 320);
        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
