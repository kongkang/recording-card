//! 点一机 V1 离线 `.amr`（AMR-WB 16kHz）转标准 16kHz 单声道 WAV。

use std::path::Path;

use reai_dyj_sdk::audio::{
    wav_bytes, AmrWbDecoder, AMR_WB_MAGIC, SAMPLE_RATE_HZ, WB_PAYLOAD_BYTES,
};

pub struct TranscodeOutput {
    pub samples: usize,
    pub duration_secs: f64,
}

/// 判断文件是否为 AMR-WB 格式（扩展名 `.amr` 或文件头 `#!AMR-WB\n`）。
pub fn is_amr_wb_file(path: &Path, head: &[u8]) -> bool {
    if head.starts_with(AMR_WB_MAGIC) {
        return true;
    }
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("amr"))
        .unwrap_or(false)
}

/// 解码标准 AMR-WB 文件（含或不含 `#!AMR-WB\n` 魔数头）并写出 16kHz 单声道 WAV。
pub async fn amr_wb_to_wav(amr_path: &Path, wav_path: &Path) -> Result<TranscodeOutput, String> {
    let raw = tokio::fs::read(amr_path)
        .await
        .map_err(|e| format!("read amr {}: {e}", amr_path.display()))?;
    let mut cursor = if raw.starts_with(AMR_WB_MAGIC) {
        AMR_WB_MAGIC.len()
    } else {
        0
    };

    let mut decoder = AmrWbDecoder::new();
    let mut pcm: Vec<i16> = Vec::with_capacity((raw.len() / 33) * 320);

    while cursor < raw.len() {
        let toc = raw[cursor];
        let mode = ((toc >> 3) & 0x0F) as usize;
        // AMR-WB SID / NO_DATA 帧处理：mode 9 = SID (5B payload), mode 14/15 = speech lost / no data (0B)
        let frame_len = if mode <= 8 {
            1 + WB_PAYLOAD_BYTES[mode]
        } else if mode == 9 {
            6
        } else if mode == 14 || mode == 15 {
            1
        } else {
            // 遇到损坏字节向前滑动一字节尝试重新同步
            cursor += 1;
            continue;
        };
        if cursor + frame_len > raw.len() {
            break;
        }
        if mode <= 8 {
            if let Some(decoded) = decoder.decode(&raw[cursor..cursor + frame_len]) {
                pcm.extend_from_slice(&decoded);
            }
        } else if mode == 15 {
            // NO_DATA 静音帧：填 20ms（320 样本）静音保持时间轴严格对齐
            pcm.extend(std::iter::repeat_n(0i16, 320));
        }
        cursor += frame_len;
    }

    if let Some(parent) = wav_path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let wav = wav_bytes(&pcm, SAMPLE_RATE_HZ);
    tokio::fs::write(wav_path, wav)
        .await
        .map_err(|e| format!("write wav {}: {e}", wav_path.display()))?;

    let samples = pcm.len();
    Ok(TranscodeOutput {
        samples,
        duration_secs: samples as f64 / SAMPLE_RATE_HZ as f64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn decodes_amr_wb_file_with_magic_header_to_16khz_wav() {
        let frame: [u8; 33] = [
            0x14, 0x50, 0x46, 0x0c, 0x15, 0x17, 0x57, 0x22, 0x71, 0x71, 0x42, 0x0a, 0x16, 0x97,
            0x72, 0xbf, 0xbc, 0x56, 0xc6, 0x4e, 0x4c, 0x46, 0xc7, 0xdf, 0xd4, 0x4f, 0x56, 0xd6,
            0x55, 0x16, 0x5b, 0xc4, 0x50,
        ];
        let mut bytes = Vec::from(AMR_WB_MAGIC);
        bytes.extend_from_slice(&frame);
        bytes.extend_from_slice(&frame);

        let dir = std::env::temp_dir().join(format!("rc-amr-test-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let amr = dir.join("sample.amr");
        let wav = dir.join("sample.wav");
        tokio::fs::write(&amr, &bytes).await.unwrap();

        assert!(is_amr_wb_file(&amr, &bytes[..10]));
        let out = amr_wb_to_wav(&amr, &wav).await.unwrap();
        assert_eq!(out.samples, 640);
        let written = tokio::fs::read(&wav).await.unwrap();
        assert_eq!(&written[..4], b"RIFF");
        assert_eq!(written.len(), 44 + 640 * 2);
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }
}
