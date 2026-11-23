//! Omi 硬件 BLE 全接口与 Ring Buffer 深度探针（仅供真机 E2E 测试调用）。
//!
//! 用法：
//!   cargo run --release --example omi_ble_e2e_probe -- gatt-and-realtime <evidence_dir>
//!   cargo run --release --example omi_ble_e2e_probe -- storage-ring <evidence_dir>
//!
//! 红线约定：
//! - 严禁连接或写入任何非 Omi 设备（如 DYJV2_* 录音卡）。
//! - `gatt-and-realtime` 阶段绝不向 `30295781`（Storage Data）写入任何命令，避免触发固件 3.0.21 实时流挂起。

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use btleplug::api::{
    Central, CentralEvent, CharPropFlags, Characteristic, Manager as _, Peripheral as _,
    ScanFilter, WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use reai_ext_sdk::audio::write_wav_16k_mono;
use reai_ext_sdk::{RecorderSdkDriver, SdkAudioChunk, SdkDeviceEvent};
use reai_omi_sdk::protocol::{
    decode_button_gesture, extract_ring_encoded_frames, parse_ring_info, OmiAudioCodec,
    OmiFrameDecoder, OmiPacketReassembler, CHR_BATTERY_LEVEL_UUID, CHR_FW_REV_UUID,
    CHR_MODEL_NUMBER_UUID, CHR_OMI_AUDIO_CODEC_UUID, CHR_OMI_AUDIO_DATA_UUID,
    CHR_OMI_BUTTON_TRIGGER_UUID, CHR_OMI_CHARGING_UUID, CHR_OMI_MUTE_UUID,
    CHR_OMI_STORAGE_CTRL_UUID, CHR_OMI_STORAGE_DATA_UUID, CHR_OMI_TIMESYNC_WRITE_UUID,
    RING_CMD_ADVANCE, RING_CMD_INFO, RING_CMD_READ, RING_CMD_STOP, RING_NOTIFY_ACK,
    RING_NOTIFY_DATA, RING_NOTIFY_DONE, RING_NOTIFY_READ_BEGIN, SVC_BATTERY_UUID, SVC_DIS_UUID,
    SVC_OMI_AUDIO_UUID, SVC_OMI_BUTTON_UUID, SVC_OMI_SETTINGS_UUID, SVC_OMI_STORAGE_UUID,
    SVC_OMI_TIMESYNC_UUID,
};
use reai_omi_sdk::OmiSdkDriver;
use serde_json::{json, Value};
use uuid::Uuid;

struct VolumeGuard {
    original_volume: Option<u8>,
}

impl VolumeGuard {
    fn capture_and_set(target: u8) -> Self {
        let orig = read_mac_output_volume();
        if orig.is_some() {
            set_mac_output_volume(target);
        }
        Self {
            original_volume: orig,
        }
    }

    fn set(&self, vol: u8) {
        if self.original_volume.is_some() {
            set_mac_output_volume(vol);
        }
    }
}

impl Drop for VolumeGuard {
    fn drop(&mut self) {
        if let Some(orig) = self.original_volume {
            set_mac_output_volume(orig);
            eprintln!("[probe] 已恢复 Mac Studio扬声器系统音量至 {orig}");
        }
    }
}

fn read_mac_output_volume() -> Option<u8> {
    let out = Command::new("osascript")
        .args(["-e", "output volume of (get volume settings)"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse::<u8>()
        .ok()
}

fn set_mac_output_volume(vol: u8) {
    let _ = Command::new("osascript")
        .args(["-e", &format!("set volume output volume {}", vol.min(100))])
        .status();
}

fn speak_via_mac_speaker(voice: &str, text: &str) -> Result<Duration, String> {
    let started = Instant::now();
    let status = Command::new("say")
        .args(["-a", "Mac Studio扬声器", "-v", voice, text])
        .status()
        .map_err(|e| format!("say 启动失败: {e}"))?;
    if !status.success() {
        return Err(format!("say 退出码异常: {status}"));
    }
    Ok(started.elapsed())
}

fn format_props(flags: CharPropFlags) -> Vec<&'static str> {
    let mut out = Vec::new();
    if flags.contains(CharPropFlags::READ) {
        out.push("READ");
    }
    if flags.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE) {
        out.push("WRITE_WITHOUT_RESPONSE");
    }
    if flags.contains(CharPropFlags::WRITE) {
        out.push("WRITE");
    }
    if flags.contains(CharPropFlags::NOTIFY) {
        out.push("NOTIFY");
    }
    if flags.contains(CharPropFlags::INDICATE) {
        out.push("INDICATE");
    }
    out
}

fn hex_string(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn compute_pcm_stats(samples: &[i16]) -> Value {
    if samples.is_empty() {
        return json!({
            "samples": 0,
            "durationSecs": 0.0,
            "rmsDbfs": null,
            "peakDbfs": null,
            "peakAbs": 0
        });
    }
    let mut sum_sq = 0.0f64;
    let mut peak = 0i32;
    for &s in samples {
        let a = i32::from(s).abs();
        if a > peak {
            peak = a;
        }
        let f = f64::from(s) / 32768.0;
        sum_sq += f * f;
    }
    let rms = (sum_sq / samples.len() as f64).sqrt();
    let rms_db = if rms > 1e-9 {
        20.0 * rms.log10()
    } else {
        -96.0
    };
    let peak_f = f64::from(peak) / 32768.0;
    let peak_db = if peak_f > 1e-9 {
        20.0 * peak_f.log10()
    } else {
        -96.0
    };
    json!({
        "samples": samples.len(),
        "durationSecs": (samples.len() as f64 / 16_000.0 * 1000.0).round() / 1000.0,
        "rmsDbfs": (rms_db * 100.0).round() / 100.0,
        "peakDbfs": (peak_db * 100.0).round() / 100.0,
        "peakAbs": peak
    })
}

#[derive(Clone)]
struct ScannedOmi {
    peripheral: Peripheral,
    id: String,
    name: String,
    rssi: Option<i16>,
    services: Vec<String>,
    manufacturer_data: BTreeMap<u16, String>,
    advertised_in_window: bool,
}

async fn scan_for_omi(
    adapter: &Adapter,
    timeout: Duration,
) -> Result<(Vec<ScannedOmi>, Vec<Value>), Box<dyn std::error::Error>> {
    let mut events = adapter.events().await?;
    let mut seen: HashSet<String> = HashSet::new();
    adapter.start_scan(ScanFilter::default()).await?;
    let pump = async {
        while let Some(ev) = events.next().await {
            let id = match ev {
                CentralEvent::DeviceDiscovered(id)
                | CentralEvent::DeviceUpdated(id)
                | CentralEvent::ManufacturerDataAdvertisement { id, .. }
                | CentralEvent::ServiceDataAdvertisement { id, .. }
                | CentralEvent::ServicesAdvertisement { id, .. } => id,
                _ => continue,
            };
            seen.insert(id.to_string());
        }
    };
    let _ = tokio::time::timeout(timeout, pump).await;
    let _ = adapter.stop_scan().await;

    let peripherals = adapter.peripherals().await?;
    let mut omis = Vec::new();
    let mut ignored = Vec::new();
    for p in peripherals {
        let Ok(Some(props)) = p.properties().await else {
            continue;
        };
        let pid = p.id().to_string();
        let in_window = seen.contains(&pid);
        let local_name = props.local_name.clone();
        let is_omi = OmiSdkDriver.matches_advertisement(
            local_name.as_deref(),
            &props.services,
            &props.manufacturer_data,
        );
        if is_omi {
            let name = local_name
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| OmiSdkDriver.fallback_ble_name(&pid));
            let mut mfd = BTreeMap::new();
            for (k, v) in &props.manufacturer_data {
                mfd.insert(*k, hex_string(v));
            }
            omis.push(ScannedOmi {
                peripheral: p,
                id: pid,
                name,
                rssi: props.rssi,
                services: props.services.iter().map(|u| u.to_string()).collect(),
                manufacturer_data: mfd,
                advertised_in_window: in_window,
            });
        } else if in_window {
            if let Some(ref n) = local_name {
                if !n.trim().is_empty() {
                    ignored.push(json!({
                        "id": pid,
                        "name": n,
                        "rssi": props.rssi,
                    }));
                }
            }
        }
    }
    omis.sort_by(|a, b| {
        b.advertised_in_window
            .cmp(&a.advertised_in_window)
            .then_with(|| b.rssi.unwrap_or(-100).cmp(&a.rssi.unwrap_or(-100)))
    });
    Ok((omis, ignored))
}

async fn write_char_auto(
    peripheral: &Peripheral,
    ch: &Characteristic,
    data: &[u8],
) -> Result<&'static str, String> {
    let (wt, label) = if ch.properties.contains(CharPropFlags::WRITE) {
        (WriteType::WithResponse, "WithResponse")
    } else {
        (WriteType::WithoutResponse, "WithoutResponse")
    };
    peripheral
        .write(ch, data, wt)
        .await
        .map_err(|e| format!("{e}"))?;
    Ok(label)
}

async fn run_audio_capture_window(
    notif_stream: &mut (impl futures::Stream<Item = btleplug::api::ValueNotification> + Unpin),
    audio_uuid: Uuid,
    codec: OmiAudioCodec,
    duration: Duration,
) -> Value {
    let start = Instant::now();
    let deadline = tokio::time::Instant::now() + duration;
    let mut per_sec: BTreeMap<u64, u64> = BTreeMap::new();
    let mut size_hist: BTreeMap<usize, u64> = BTreeMap::new();
    let mut raw_packets = 0u64;
    let mut gap_count = 0u64;
    let mut frames_ok = 0u64;
    let mut decode_errors = 0u64;
    let mut reassembler = OmiPacketReassembler::default();
    let mut decoder = OmiFrameDecoder::for_codec(codec).unwrap_or(OmiFrameDecoder::Pcm16);
    let mut pcm_all: Vec<i16> = Vec::new();
    let mut first_pkt_ms: Option<u64> = None;
    let mut last_pkt_ms: Option<u64> = None;

    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            break;
        }
        let rem = deadline - now;
        match tokio::time::timeout(rem, notif_stream.next()).await {
            Ok(Some(notif)) => {
                if notif.uuid != audio_uuid {
                    continue;
                }
                let elapsed = start.elapsed();
                let ms = elapsed.as_millis() as u64;
                if first_pkt_ms.is_none() {
                    first_pkt_ms = Some(ms);
                }
                last_pkt_ms = Some(ms);
                raw_packets += 1;
                *per_sec.entry(elapsed.as_secs()).or_insert(0) += 1;
                *size_hist.entry(notif.value.len()).or_insert(0) += 1;

                if let Some(frame) = reassembler.push_packet(&notif.value) {
                    if frame.discontinuous {
                        gap_count += 1;
                    }
                    match decoder.decode_frame(&frame.data) {
                        Ok(samples) => {
                            frames_ok += 1;
                            pcm_all.extend_from_slice(&samples);
                        }
                        Err(_) => {
                            decode_errors += 1;
                        }
                    }
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }
    if let Some(tail) = reassembler.flush() {
        if let Ok(samples) = decoder.decode_frame(&tail) {
            frames_ok += 1;
            pcm_all.extend_from_slice(&samples);
        }
    }

    json!({
        "rawPackets": raw_packets,
        "framesOk": frames_ok,
        "decodeErrors": decode_errors,
        "packetIdGaps": gap_count,
        "firstPacketMs": first_pkt_ms,
        "lastPacketMs": last_pkt_ms,
        "perSecondPackets": per_sec,
        "packetLengthHistogram": size_hist,
        "pcmStats": compute_pcm_stats(&pcm_all),
        "_pcm": pcm_all,
    })
}

async fn mode_gatt_and_realtime(
    adapter: &Adapter,
    evidence_dir: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    std::fs::create_dir_all(evidence_dir)?;
    let vol_guard = VolumeGuard::capture_and_set(55);
    eprintln!(
        "[probe] 初始系统音量={:?}，测试期设为 55",
        vol_guard.original_volume
    );

    // 1.1 Scan
    eprintln!("[probe] 1.1 扫描 Omi 广播 (8s)...");
    let (omis, ignored) = scan_for_omi(adapter, Duration::from_secs(8)).await?;
    let target = omis
        .into_iter()
        .find(|o| o.advertised_in_window)
        .or_else(|| None)
        .ok_or("未扫描到正在广播的 Omi 设备")?;
    eprintln!(
        "[probe] 命中 Omi: name={} id={} rssi={:?} services={:?}",
        target.name, target.id, target.rssi, target.services
    );
    eprintln!("[probe] 已安全忽略非 Omi 广播设备数={}", ignored.len());

    // 1.2 Connect & Full GATT Enumeration
    eprintln!("[probe] 1.2 连接并枚举全量 GATT 服务/特征...");
    let t_conn = Instant::now();
    tokio::time::timeout(Duration::from_secs(18), target.peripheral.connect()).await??;
    tokio::time::timeout(Duration::from_secs(15), target.peripheral.discover_services()).await??;
    let connect_ms = t_conn.elapsed().as_millis() as u64;

    let chars = target.peripheral.characteristics();
    let services = target.peripheral.services();

    let mut gatt_services = Vec::new();
    for svc in &services {
        let mut svc_chars = Vec::new();
        for c in &svc.characteristics {
            svc_chars.push(json!({
                "uuid": c.uuid.to_string(),
                "properties": format_props(c.properties),
            }));
        }
        gatt_services.push(json!({
            "uuid": svc.uuid.to_string(),
            "primary": svc.primary,
            "characteristics": svc_chars,
        }));
    }

    // 1.3 Passive Read of ALL READ characteristics (never write 30295781!)
    eprintln!("[probe] 1.3 被动读取全部只读特征...");
    let mut passive_reads = Vec::new();
    for c in &chars {
        if !c.properties.contains(CharPropFlags::READ) {
            continue;
        }
        let read_res =
            tokio::time::timeout(Duration::from_secs(3), target.peripheral.read(c)).await;
        let entry = match read_res {
            Ok(Ok(bytes)) => {
                let utf8 = String::from_utf8_lossy(&bytes)
                    .trim_end_matches('\0')
                    .trim()
                    .to_string();
                let u8_first = bytes.first().copied();
                let u32_le = if bytes.len() >= 4 {
                    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
                } else {
                    None
                };
                json!({
                    "service": c.service_uuid.to_string(),
                    "characteristic": c.uuid.to_string(),
                    "len": bytes.len(),
                    "hex": hex_string(&bytes),
                    "utf8": utf8,
                    "firstByte": u8_first,
                    "u32Le": u32_le,
                })
            }
            Ok(Err(e)) => json!({
                "service": c.service_uuid.to_string(),
                "characteristic": c.uuid.to_string(),
                "error": e.to_string(),
            }),
            Err(_) => json!({
                "service": c.service_uuid.to_string(),
                "characteristic": c.uuid.to_string(),
                "error": "read timeout",
            }),
        };
        passive_reads.push(entry);
    }

    // Extract Codec
    let audio_codec_char = chars.iter().find(|c| c.uuid == CHR_OMI_AUDIO_CODEC_UUID).cloned();
    let codec_raw = if let Some(ref c) = audio_codec_char {
        target.peripheral.read(c).await.ok()
    } else {
        None
    };
    let codec_id = codec_raw.as_ref().and_then(|b| b.first().copied()).unwrap_or(20);
    let codec = OmiAudioCodec::from_codec_id(codec_id);
    eprintln!("[probe] Audio Codec ID={codec_id} -> {codec:?}");

    // Test BAS & Button subscribe + TimeSync write
    let battery_sub_ok = if let Some(c) = chars.iter().find(|c| c.uuid == CHR_BATTERY_LEVEL_UUID) {
        target.peripheral.subscribe(c).await.is_ok()
    } else {
        false
    };
    let button_sub_ok = if let Some(c) = chars.iter().find(|c| c.uuid == CHR_OMI_BUTTON_TRIGGER_UUID) {
        target.peripheral.subscribe(c).await.is_ok()
    } else {
        false
    };
    let timesync_res = if let Some(tc) = chars.iter().find(|c| c.uuid == CHR_OMI_TIMESYNC_WRITE_UUID) {
        let now_sec = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as u32;
        let w = write_char_auto(&target.peripheral, tc, &now_sec.to_le_bytes()).await;
        let readback = if tc.properties.contains(CharPropFlags::READ) {
            target
                .peripheral
                .read(tc)
                .await
                .ok()
                .map(|b| hex_string(&b))
        } else {
            None
        };
        json!({
            "present": true,
            "epochWritten": now_sec,
            "writeResult": w,
            "readbackHex": readback,
        })
    } else {
        json!({"present": false})
    };

    // Check presence of 19b10013, 19b10015, 30295781, 30295782
    let find_char_summary = |uuid: Uuid| -> Value {
        match chars.iter().find(|c| c.uuid == uuid) {
            Some(c) => json!({
                "present": true,
                "service": c.service_uuid.to_string(),
                "properties": format_props(c.properties),
            }),
            None => json!({"present": false}),
        }
    };

    // 1.4 Raw realtime audio protocol + VAD gate + calibration
    eprintln!("[probe] 1.4 实时音频流 VAD 门控与声学校准...");
    let audio_data_char = chars
        .iter()
        .find(|c| c.uuid == CHR_OMI_AUDIO_DATA_UUID)
        .cloned()
        .ok_or("缺少 CHR_OMI_AUDIO_DATA_UUID")?;
    let mut notif_stream = target.peripheral.notifications().await?;
    target.peripheral.subscribe(&audio_data_char).await?;

    // Stage A: 10s Silence
    eprintln!("[probe]   Stage A: 10s 静默期（观察预滚包与 VAD 静默门控）...");
    let mut silence_report =
        run_audio_capture_window(&mut notif_stream, CHR_OMI_AUDIO_DATA_UUID, codec, Duration::from_secs(10)).await;
    silence_report.as_object_mut().map(|m| m.remove("_pcm"));

    // Stage B: Acoustic speech calibration at vol 55 (retry at 65 if RMS < -40 dBFS)
    let mut calibration_attempts = Vec::new();
    let mut final_calib_pcm: Vec<i16> = Vec::new();
    for &vol in &[55u8, 65u8] {
        vol_guard.set(vol);
        eprintln!("[probe]   Stage B: 音量={vol} 播放测试语音...");
        let stream_fut = run_audio_capture_window(
            &mut notif_stream,
            CHR_OMI_AUDIO_DATA_UUID,
            codec,
            Duration::from_secs(12),
        );
        let speech_fut = tokio::task::spawn_blocking(|| {
            speak_via_mac_speaker(
                "Flo (中文（中国大陆）)",
                "欧米蓝牙协议层声学校准测试，一二三四五，音频帧重组与解码正常。",
            )
        });
        let (mut cap, say_res) = tokio::join!(stream_fut, speech_fut);
        let pcm_vec: Vec<i16> = cap
            .get("_pcm")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_i64().map(|x| x as i16))
                    .collect()
            })
            .unwrap_or_default();
        cap.as_object_mut().map(|m| m.remove("_pcm"));
        let rms = cap
            .get("pcmStats")
            .and_then(|s| s.get("rmsDbfs"))
            .and_then(Value::as_f64)
            .unwrap_or(-96.0);
        let say_ms = match say_res {
            Ok(Ok(d)) => d.as_millis() as u64,
            _ => 0,
        };
        eprintln!(
            "[probe]   vol={vol} -> rawPkts={} framesOk={} samples={} rmsDbfs={rms}",
            cap["rawPackets"], cap["framesOk"], pcm_vec.len(),
        );
        final_calib_pcm = pcm_vec;
        calibration_attempts.push(json!({
            "volume": vol,
            "sayDurationMs": say_ms,
            "capture": cap,
        }));
        if rms >= -40.0 && !final_calib_pcm.is_empty() {
            break;
        }
    }

    let calib_wav = evidence_dir.join("phase1_calib.wav");
    if !final_calib_pcm.is_empty() {
        write_wav_16k_mono(&calib_wav, &final_calib_pcm)?;
    }

    drop(notif_stream);
    let _ = target.peripheral.unsubscribe(&audio_data_char).await;
    target.peripheral.disconnect().await?;
    tokio::time::sleep(Duration::from_secs(3)).await;

    // 1.5 OmiSdkDriver full trait verification
    eprintln!("[probe] 1.5 验证 OmiSdkDriver (RecorderSdkDriver / RecorderDevice) 全契约...");
    let (omis2, _) = scan_for_omi(adapter, Duration::from_secs(6)).await?;
    let target2 = omis2
        .into_iter()
        .find(|o| o.advertised_in_window)
        .ok_or("断开后重新扫描未发现 Omi 广播")?;
    let sdk_dev = OmiSdkDriver.connect(target2.peripheral, target2.name.clone()).await?;
    let mut sdk_events_rx = sdk_dev.subscribe_events();
    let mut sdk_audio_rx = sdk_dev.subscribe_audio();

    let snap_init = sdk_dev.snapshot().await?;
    let sync_time_val = sdk_dev.sync_time().await?;
    let start_rec_val = sdk_dev.start_record(None).await?;
    let mark_val = sdk_dev.mark().await?;
    sdk_dev.set_realtime_enabled(true).await?;

    let sdk_speak_task = tokio::task::spawn_blocking(|| {
        speak_via_mac_speaker("Flo (中文（中国大陆）)", "驱动层实时音频接收验证完成。")
    });
    let mut sdk_chunks = 0u64;
    let mut sdk_samples = 0u64;
    let mut sdk_sample_rate = 0u32;
    let mut sdk_channels = 0u8;
    let mut sdk_discont = 0u64;
    let sdk_deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    loop {
        let now = tokio::time::Instant::now();
        if now >= sdk_deadline {
            break;
        }
        match tokio::time::timeout(sdk_deadline - now, sdk_audio_rx.recv()).await {
            Ok(Ok(SdkAudioChunk {
                samples,
                sample_rate,
                channels,
                discontinuous,
            })) => {
                sdk_chunks += 1;
                sdk_samples += samples.len() as u64;
                sdk_sample_rate = sample_rate;
                sdk_channels = channels;
                if discontinuous {
                    sdk_discont += 1;
                }
            }
            _ => break,
        }
    }
    let _ = sdk_speak_task.await;
    sdk_dev.set_realtime_enabled(false).await?;
    let stop_rec_val = sdk_dev.stop_record().await?;

    let mut sdk_events = Vec::new();
    while let Ok(ev) = sdk_events_rx.try_recv() {
        sdk_events.push(match ev {
            SdkDeviceEvent::RecordStatus(st) => json!({"kind": "record", "status": st}),
            SdkDeviceEvent::Power(b) => json!({"kind": "power", "battery": b}),
            SdkDeviceEvent::VoiceKey { pressed } => json!({"kind": "voice_key", "pressed": pressed}),
            SdkDeviceEvent::Button { gesture } => json!({"kind": "button", "gesture": gesture}),
            SdkDeviceEvent::Disconnected => json!({"kind": "disconnected"}),
        });
    }

    sdk_dev.disconnect().await?;
    tokio::time::sleep(Duration::from_secs(3)).await;
    let (omis3, _) = scan_for_omi(adapter, Duration::from_secs(6)).await?;
    let resumed_advertising = omis3.iter().any(|o| o.advertised_in_window);

    let report = json!({
        "generatedAtEpochSec": SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
        "mode": "gatt-and-realtime",
        "scan": {
            "target": {
                "id": target.id,
                "name": target.name,
                "rssi": target.rssi,
                "services": target.services,
                "manufacturerData": target.manufacturer_data,
            },
            "ignoredAdvertisingDevices": ignored,
        },
        "gatt": {
            "connectAndDiscoverMs": connect_ms,
            "services": gatt_services,
            "passiveReads": passive_reads,
            "knownCharacteristics": {
                "audioData": find_char_summary(CHR_OMI_AUDIO_DATA_UUID),
                "audioCodec": find_char_summary(CHR_OMI_AUDIO_CODEC_UUID),
                "batteryLevel": find_char_summary(CHR_BATTERY_LEVEL_UUID),
                "charging": find_char_summary(CHR_OMI_CHARGING_UUID),
                "mute": find_char_summary(CHR_OMI_MUTE_UUID),
                "buttonTrigger": find_char_summary(CHR_OMI_BUTTON_TRIGGER_UUID),
                "timeSync": find_char_summary(CHR_OMI_TIMESYNC_WRITE_UUID),
                "storageData": find_char_summary(CHR_OMI_STORAGE_DATA_UUID),
                "storageCtrl": find_char_summary(CHR_OMI_STORAGE_CTRL_UUID),
                "disModelNumber": find_char_summary(CHR_MODEL_NUMBER_UUID),
                "disFwRevision": find_char_summary(CHR_FW_REV_UUID),
                "svcOmiAudio": SVC_OMI_AUDIO_UUID.to_string(),
                "svcOmiSettings": SVC_OMI_SETTINGS_UUID.to_string(),
                "svcOmiButton": SVC_OMI_BUTTON_UUID.to_string(),
                "svcOmiTimesync": SVC_OMI_TIMESYNC_UUID.to_string(),
                "svcOmiStorage": SVC_OMI_STORAGE_UUID.to_string(),
                "svcBattery": SVC_BATTERY_UUID.to_string(),
                "svcDis": SVC_DIS_UUID.to_string(),
            },
            "codecId": codec_id,
            "codecMapped": format!("{codec:?}"),
            "batterySubscribeOk": battery_sub_ok,
            "buttonSubscribeOk": button_sub_ok,
            "timeSync": timesync_res,
        },
        "rawRealtime": {
            "silenceWindow": silence_report,
            "calibrationAttempts": calibration_attempts,
            "calibWavPath": calib_wav.to_string_lossy(),
        },
        "omiSdkDriver": {
            "snapshot": snap_init,
            "syncTime": sync_time_val,
            "startRecord": start_rec_val,
            "mark": mark_val,
            "stopRecord": stop_rec_val,
            "realtimeChunks": sdk_chunks,
            "realtimeSamples": sdk_samples,
            "sampleRate": sdk_sample_rate,
            "channels": sdk_channels,
            "discontinuousChunks": sdk_discont,
            "events": sdk_events,
            "resumedAdvertisingAfterDisconnect": resumed_advertising,
        }
    });

    let out_path = evidence_dir.join("phase1_rust_gatt_realtime.json");
    std::fs::write(&out_path, serde_json::to_string_pretty(&report)?)?;
    eprintln!("[probe] 阶段 1 完成，证据已写入 {}", out_path.display());
    Ok(())
}

async fn query_ring_info_raw(
    peripheral: &Peripheral,
    sdata: &Characteristic,
    notif_stream: &mut (impl futures::Stream<Item = btleplug::api::ValueNotification> + Unpin),
) -> Option<reai_omi_sdk::protocol::RingBufferInfo> {
    let _ = write_char_auto(peripheral, sdata, &[RING_CMD_INFO]).await.ok()?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(4);
    while tokio::time::Instant::now() < deadline {
        let rem = deadline - tokio::time::Instant::now();
        match tokio::time::timeout(rem, notif_stream.next()).await {
            Ok(Some(n)) if n.uuid == sdata.uuid => {
                if let Some(info) = parse_ring_info(&n.value) {
                    return Some(info);
                }
                if n.value.first().copied() == Some(RING_NOTIFY_ACK) {
                    continue;
                }
            }
            Ok(Some(_)) => continue,
            _ => break,
        }
    }
    None
}

async fn test_audio_alive(
    notif_stream: &mut (impl futures::Stream<Item = btleplug::api::ValueNotification> + Unpin),
    audio_uuid: Uuid,
    codec: OmiAudioCodec,
    phrase: &str,
) -> Value {
    let cap_fut = run_audio_capture_window(notif_stream, audio_uuid, codec, Duration::from_secs(7));
    let phrase_owned = phrase.to_string();
    let say_fut = tokio::task::spawn_blocking(move || {
        speak_via_mac_speaker("Flo (中文（中国大陆）)", &phrase_owned)
    });
    let (mut cap, _) = tokio::join!(cap_fut, say_fut);
    cap.as_object_mut().map(|m| m.remove("_pcm"));
    cap
}

async fn mode_storage_ring(
    adapter: &Adapter,
    evidence_dir: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    std::fs::create_dir_all(evidence_dir)?;
    let vol_guard = VolumeGuard::capture_and_set(55);
    let (omis, _) = scan_for_omi(adapter, Duration::from_secs(8)).await?;
    let target = omis
        .into_iter()
        .find(|o| o.advertised_in_window)
        .ok_or("未扫描到 Omi")?;

    let mut peripheral = target.peripheral;
    tokio::time::timeout(Duration::from_secs(18), peripheral.connect()).await??;
    tokio::time::timeout(Duration::from_secs(15), peripheral.discover_services()).await??;

    let chars = peripheral.characteristics();
    let audio_char = chars
        .iter()
        .find(|c| c.uuid == CHR_OMI_AUDIO_DATA_UUID)
        .cloned()
        .ok_or("缺少 audio char")?;
    let codec_id = if let Some(c) = chars.iter().find(|c| c.uuid == CHR_OMI_AUDIO_CODEC_UUID) {
        peripheral
            .read(c)
            .await
            .ok()
            .and_then(|b| b.first().copied())
            .unwrap_or(21)
    } else {
        21
    };
    let codec = OmiAudioCodec::from_codec_id(codec_id);
    if let Some(tc) = chars.iter().find(|c| c.uuid == CHR_OMI_TIMESYNC_WRITE_UUID) {
        let now_sec = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as u32;
        let _ = write_char_auto(&peripheral, tc, &now_sec.to_le_bytes()).await;
    }

    let sdata = chars
        .iter()
        .find(|c| c.uuid == CHR_OMI_STORAGE_DATA_UUID)
        .cloned()
        .ok_or("缺少 storage data char")?;
    let sctrl = chars
        .iter()
        .find(|c| c.uuid == CHR_OMI_STORAGE_CTRL_UUID)
        .cloned();
    let sctrl_read = if let Some(ref sc) = sctrl {
        if sc.properties.contains(CharPropFlags::READ) {
            peripheral.read(sc).await.ok().map(|b| hex_string(&b))
        } else {
            None
        }
    } else {
        None
    };

    peripheral.subscribe(&sdata).await?;
    peripheral.subscribe(&audio_char).await?;
    let mut notif_stream = peripheral.notifications().await?;

    // Baseline RING_CMD_INFO (0x10)
    let mut info0 = query_ring_info_raw(&peripheral, &sdata, &mut notif_stream)
        .await
        .ok_or("RING_CMD_INFO 0x10 未返回有效 RingBufferInfo")?;
    eprintln!("[ring] 初始 RingBufferInfo: {info0:?}");

    // Experiment A: Does 0x10 alone suspend 19b10001 realtime stream?
    eprintln!("[ring] 实验 A: 验证 0x10 查询后实时流是否存活...");
    let exp_a = test_audio_alive(
        &mut notif_stream,
        CHR_OMI_AUDIO_DATA_UUID,
        codec,
        "存储信息查询后的实时流连通性验证，一二三四五。",
    )
    .await;
    eprintln!("[ring] 实验 A rawPackets={}", exp_a["rawPackets"]);

    // Ensure enough fresh records exist if backlog == 0
    if info0.write_seq <= info0.read_seq {
        eprintln!("[ring] 当前积压为 0，先发声录制 8 秒进入 Ring Buffer...");
        let _ = tokio::task::spawn_blocking(|| {
            speak_via_mac_speaker(
                "Flo (中文（中国大陆）)",
                "补充录制板载环形存储测试语音，今天是十一月十九日，测试离线同步。",
            )
        })
        .await;
        tokio::time::sleep(Duration::from_secs(2)).await;
        if let Some(updated) = query_ring_info_raw(&peripheral, &sdata, &mut notif_stream).await {
            info0 = updated;
        }
    }

    // Experiment B: Read recent <= 60 records via 0x11
    let backlog = info0.write_seq.saturating_sub(info0.read_seq);
    let read_count = u32::try_from(backlog.min(60)).unwrap_or(60);
    let read_start = info0.write_seq.saturating_sub(u64::from(read_count));
    eprintln!("[ring] 实验 B: 读取 [{read_start}, {}) 共 {read_count} 条...", info0.write_seq);

    let mut read_cmd = Vec::with_capacity(13);
    read_cmd.push(RING_CMD_READ);
    read_cmd.extend_from_slice(&read_start.to_be_bytes());
    read_cmd.extend_from_slice(&read_count.to_be_bytes());
    let dl_start = Instant::now();
    let _ = write_char_auto(&peripheral, &sdata, &read_cmd).await?;

    let mut notify_counts: BTreeMap<String, u64> = BTreeMap::new();
    let mut raw_ring = Vec::new();
    let mut seen_done = false;
    let dl_deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while tokio::time::Instant::now() < dl_deadline {
        let rem = dl_deadline - tokio::time::Instant::now();
        match tokio::time::timeout(rem.min(Duration::from_secs(6)), notif_stream.next()).await {
            Ok(Some(n)) if n.uuid == CHR_OMI_STORAGE_DATA_UUID && !n.value.is_empty() => {
                let code = n.value[0];
                let key = format!("0x{code:02X}");
                *notify_counts.entry(key).or_insert(0) += 1;
                match code {
                    RING_NOTIFY_DATA => raw_ring.extend_from_slice(&n.value[1..]),
                    RING_NOTIFY_DONE => {
                        seen_done = true;
                        break;
                    }
                    RING_NOTIFY_ACK | RING_NOTIFY_READ_BEGIN => continue,
                    _ => continue,
                }
            }
            Ok(Some(_)) => continue,
            _ => break,
        }
    }
    let dl_ms = dl_start.elapsed().as_millis() as u64;
    let throughput_kbps = if dl_ms > 0 {
        (raw_ring.len() as f64 / 1024.0) / (dl_ms as f64 / 1000.0)
    } else {
        0.0
    };
    let (first_ts, ring_frames) = extract_ring_encoded_frames(&raw_ring);
    let mut dec = OmiFrameDecoder::for_codec(codec)?;
    let mut ring_pcm = Vec::new();
    let mut ring_decode_errs = 0u64;
    for f in &ring_frames {
        match dec.decode_frame(f) {
            Ok(s) => ring_pcm.extend_from_slice(&s),
            Err(_) => ring_decode_errs += 1,
        }
    }
    let ring_wav = evidence_dir.join("phase4_ring_sample.wav");
    if !ring_pcm.is_empty() {
        write_wav_16k_mono(&ring_wav, &ring_pcm)?;
    }
    eprintln!(
        "[ring] 实验 B 完成: bytes={} dlMs={dl_ms} speed={throughput_kbps:.2} KB/s frames={} pcmSamples={}",
        raw_ring.len(),
        ring_frames.len(),
        ring_pcm.len()
    );

    // Experiment C: Post-0x04 realtime suspension check & recovery matrix
    eprintln!("[ring] 实验 C: 验证 0x04 DONE 后 19b10001 实时流状态...");
    let exp_c_initial = test_audio_alive(
        &mut notif_stream,
        CHR_OMI_AUDIO_DATA_UUID,
        codec,
        "测试读取完成标志后的实时音频流是否挂起，一二三四五。",
    )
    .await;
    let mut recoveries = Vec::new();
    let mut alive = exp_c_initial["rawPackets"].as_u64().unwrap_or(0) > 0;

    if !alive {
        // Recovery 1: RING_CMD_STOP (0x03)
        eprintln!("[ring]   恢复尝试 1: 写入 RING_CMD_STOP (0x03)...");
        let _ = write_char_auto(&peripheral, &sdata, &[RING_CMD_STOP]).await;
        tokio::time::sleep(Duration::from_millis(500)).await;
        let r1 = test_audio_alive(
            &mut notif_stream,
            CHR_OMI_AUDIO_DATA_UUID,
            codec,
            "恢复测试一，发送停止读取指令。",
        )
        .await;
        alive = r1["rawPackets"].as_u64().unwrap_or(0) > 0;
        recoveries.push(json!({"step": "RING_CMD_STOP_0x03", "recovered": alive, "capture": r1}));
    }

    // Also advance backlog down to at most 80 records (~35 KB) so Step 4B.1 Dart E2E downloads cleanly!
    let latest_info = query_ring_info_raw(&peripheral, &sdata, &mut notif_stream)
        .await
        .unwrap_or_else(|| info0.clone());
    let keep_window = 80u64;
    let target_read_seq = if latest_info.write_seq > latest_info.read_seq + keep_window {
        latest_info.write_seq - keep_window
    } else if latest_info.write_seq > latest_info.read_seq + 20 {
        latest_info.read_seq + 1
    } else {
        latest_info.read_seq
    };

    if !alive && target_read_seq > latest_info.read_seq {
        // Recovery 2: RING_CMD_ADVANCE (0x12)
        eprintln!("[ring]   恢复尝试 2: 写入 RING_CMD_ADVANCE (0x12 -> {target_read_seq})...");
        let mut adv = Vec::with_capacity(9);
        adv.push(RING_CMD_ADVANCE);
        adv.extend_from_slice(&target_read_seq.to_be_bytes());
        let _ = write_char_auto(&peripheral, &sdata, &adv).await;
        tokio::time::sleep(Duration::from_millis(500)).await;
        let r2 = test_audio_alive(
            &mut notif_stream,
            CHR_OMI_AUDIO_DATA_UUID,
            codec,
            "恢复测试二，推进存储游标。",
        )
        .await;
        alive = r2["rawPackets"].as_u64().unwrap_or(0) > 0;
        recoveries.push(json!({"step": "RING_CMD_ADVANCE_0x12", "targetSeq": target_read_seq, "recovered": alive, "capture": r2}));
    } else if target_read_seq > latest_info.read_seq {
        let mut adv = Vec::with_capacity(9);
        adv.push(RING_CMD_ADVANCE);
        adv.extend_from_slice(&target_read_seq.to_be_bytes());
        let _ = write_char_auto(&peripheral, &sdata, &adv).await;
    }

    if !alive {
        // Recovery 3: unsubscribe + subscribe 19b10001
        eprintln!("[ring]   恢复尝试 3: unsubscribe + subscribe 19b10001...");
        let _ = peripheral.unsubscribe(&audio_char).await;
        tokio::time::sleep(Duration::from_millis(300)).await;
        let _ = peripheral.subscribe(&audio_char).await;
        let r3 = test_audio_alive(
            &mut notif_stream,
            CHR_OMI_AUDIO_DATA_UUID,
            codec,
            "恢复测试三，重新订阅音频特征。",
        )
        .await;
        alive = r3["rawPackets"].as_u64().unwrap_or(0) > 0;
        recoveries.push(json!({"step": "RESUBSCRIBE_19B10001", "recovered": alive, "capture": r3}));
    }

    if !alive {
        // Recovery 4: disconnect + reconnect
        drop(notif_stream);
        eprintln!("[ring]   恢复尝试 4: disconnect + reconnect...");
        let _ = peripheral.disconnect().await;
        tokio::time::sleep(Duration::from_secs(2)).await;
        let (omis_re, _) = scan_for_omi(adapter, Duration::from_secs(6)).await?;
        if let Some(found) = omis_re.into_iter().find(|o| o.advertised_in_window) {
            peripheral = found.peripheral;
            let _ = tokio::time::timeout(Duration::from_secs(15), peripheral.connect()).await;
            let _ = tokio::time::timeout(Duration::from_secs(15), peripheral.discover_services()).await;
            let chars_re = peripheral.characteristics();
            if let Some(ac) = chars_re.iter().find(|c| c.uuid == CHR_OMI_AUDIO_DATA_UUID).cloned() {
                let _ = peripheral.subscribe(&ac).await;
                if let Ok(mut ns_re) = peripheral.notifications().await {
                    let r4 = test_audio_alive(
                        &mut ns_re,
                        CHR_OMI_AUDIO_DATA_UUID,
                        codec,
                        "恢复测试四，蓝牙断连重连后测试实时流。",
                    )
                    .await;
                    alive = r4["rawPackets"].as_u64().unwrap_or(0) > 0;
                    recoveries.push(json!({"step": "DISCONNECT_AND_RECONNECT", "recovered": alive, "capture": r4}));
                }
            }
        } else {
            recoveries.push(json!({"step": "DISCONNECT_AND_RECONNECT", "recovered": false, "error": "重连扫描未发现 Omi"}));
        }
    }

    // Final Ring Info check
    let chars_final = peripheral.characteristics();
    let final_info = if let Some(sd) = chars_final.iter().find(|c| c.uuid == CHR_OMI_STORAGE_DATA_UUID) {
        let _ = peripheral.subscribe(sd).await;
        if let Ok(mut ns) = peripheral.notifications().await {
            query_ring_info_raw(&peripheral, sd, &mut ns).await
        } else {
            None
        }
    } else {
        None
    };

    let _ = peripheral.disconnect().await;
    drop(vol_guard);

    let report = json!({
        "generatedAtEpochSec": SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
        "mode": "storage-ring",
        "storageCtrlReadHex": sctrl_read,
        "initialRingInfo": {
            "readSeq": info0.read_seq,
            "writeSeq": info0.write_seq,
            "backlogRecords": info0.write_seq.saturating_sub(info0.read_seq),
            "capacityPackets": info0.capacity_packets,
            "droppedPackets": info0.dropped_packets,
            "packetSize": info0.packet_size,
        },
        "experimentA_after0x10Info": exp_a,
        "experimentB_ringRead": {
            "readStartSeq": read_start,
            "requestedCount": read_count,
            "seenDone": seen_done,
            "notifyCounts": notify_counts,
            "rawBytes": raw_ring.len(),
            "elapsedMs": dl_ms,
            "throughputKbps": (throughput_kbps * 100.0).round() / 100.0,
            "firstTimestampSec": first_ts,
            "encodedFrames": ring_frames.len(),
            "decodeErrors": ring_decode_errs,
            "pcmStats": compute_pcm_stats(&ring_pcm),
            "sampleWavPath": ring_wav.to_string_lossy(),
        },
        "experimentC_after0x04Done": {
            "realtimeAliveImmediately": exp_c_initial["rawPackets"].as_u64().unwrap_or(0) > 0,
            "initialCapture": exp_c_initial,
            "recoveryAttempts": recoveries,
            "finalRealtimeAlive": alive,
        },
        "finalRingInfoAfterAdvance": final_info.map(|f| json!({
            "readSeq": f.read_seq,
            "writeSeq": f.write_seq,
            "backlogRecords": f.write_seq.saturating_sub(f.read_seq),
        })),
    });

    let out_path = evidence_dir.join("phase4_ring_protocol.json");
    std::fs::write(&out_path, serde_json::to_string_pretty(&report)?)?;
    eprintln!("[ring] 阶段 4A 完成，证据已写入 {}", out_path.display());
    Ok(())
}

async fn collect_button_step(
    notif_stream: &mut (impl futures::Stream<Item = btleplug::api::ValueNotification> + Unpin),
    step_name: &str,
    prompt_zh: &str,
    max_wait_secs: u64,
    settle_ms: u64,
) -> Value {
    // 先清掉上一步可能残留在缓冲区的无关通知
    while let Ok(Some(_)) =
        tokio::time::timeout(Duration::from_millis(40), notif_stream.next()).await
    {}
    let t0 = Instant::now();
    eprintln!("[button] 播报提示 ({step_name}): {prompt_zh}");
    let _ = speak_via_mac_speaker("Flo (中文（中国大陆）)", prompt_zh);

    let mut events = Vec::new();
    let max_deadline = t0 + Duration::from_secs(max_wait_secs);
    let mut first_hit: Option<Instant> = None;
    let mut quiet_deadline: Option<Instant> = None;

    loop {
        let now = Instant::now();
        let stop_at = match quiet_deadline {
            Some(qd) => qd.min(
                first_hit
                    .map(|f| f + Duration::from_millis(5000))
                    .unwrap_or(max_deadline),
            ),
            None => max_deadline,
        };
        if now >= stop_at {
            break;
        }
        let wait = stop_at.saturating_duration_since(now);
        match tokio::time::timeout(wait, notif_stream.next()).await {
            Ok(Some(notif)) => {
                if notif.uuid == CHR_OMI_BUTTON_TRIGGER_UUID {
                    let elapsed_ms = t0.elapsed().as_millis() as u64;
                    let hex = hex_string(&notif.value);
                    let u32_le = if notif.value.len() >= 4 {
                        Some(u32::from_le_bytes([
                            notif.value[0],
                            notif.value[1],
                            notif.value[2],
                            notif.value[3],
                        ]))
                    } else {
                        None
                    };
                    let decoded = decode_button_gesture(&notif.value);
                    eprintln!(
                        "[button] 收到 {step_name} 通知 @{elapsed_ms}ms: hex=[{hex}] u32={u32_le:?} decoded={decoded:?}"
                    );
                    events.push(json!({
                        "elapsedMs": elapsed_ms,
                        "len": notif.value.len(),
                        "hex": hex,
                        "u32Le": u32_le,
                        "decodedGesture": decoded,
                    }));
                    let hit_now = Instant::now();
                    first_hit.get_or_insert(hit_now);
                    quiet_deadline = Some(hit_now + Duration::from_millis(settle_ms));
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    json!({
        "step": step_name,
        "receivedCount": events.len(),
        "events": events,
    })
}

async fn mode_button_interactive(
    adapter: &Adapter,
    evidence_dir: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    std::fs::create_dir_all(evidence_dir)?;
    let _vol = VolumeGuard::capture_and_set(62);

    eprintln!("[button] 正在扫描 Omi 硬件...");
    let (omis, _) = scan_for_omi(adapter, Duration::from_secs(7)).await?;
    let target = omis
        .into_iter()
        .find(|o| o.advertised_in_window)
        .ok_or("未扫描到 Omi 硬件，无法进行实体按键测试")?;

    eprintln!("[button] 正在连接 {} ({})...", target.name, target.id);
    let peripheral = target.peripheral;
    tokio::time::timeout(Duration::from_secs(15), peripheral.connect()).await??;
    tokio::time::timeout(Duration::from_secs(15), peripheral.discover_services()).await??;

    let chars = peripheral.characteristics();
    let btn_char = chars
        .iter()
        .find(|c| c.uuid == CHR_OMI_BUTTON_TRIGGER_UUID)
        .cloned()
        .ok_or("Omi 未暴露 23ba7925 物理按键特征")?;

    let initial_read = peripheral.read(&btn_char).await.ok().map(|b| hex_string(&b));
    peripheral.subscribe(&btn_char).await?;
    let mut notif_stream = peripheral.notifications().await?;

    let step1 = collect_button_step(
        &mut notif_stream,
        "single_tap",
        "蓝牙物理按键测试开始。第一步，请在十五秒内，单击一下欧米硬件上的物理按键。",
        20,
        1500,
    )
    .await;
    if step1["receivedCount"].as_u64().unwrap_or(0) > 0 {
        let _ = speak_via_mac_speaker("Flo (中文（中国大陆）)", "已收到单击按键信号。");
    } else {
        let _ = speak_via_mac_speaker("Flo (中文（中国大陆）)", "未检测到单击信号，继续下一步。");
    }

    let step2 = collect_button_step(
        &mut notif_stream,
        "double_tap",
        "第二步，请在十五秒内，快速双击两下欧米硬件上的物理按键。",
        20,
        1500,
    )
    .await;
    if step2["receivedCount"].as_u64().unwrap_or(0) > 0 {
        let _ = speak_via_mac_speaker("Flo (中文（中国大陆）)", "已收到双击测试信号。");
    } else {
        let _ = speak_via_mac_speaker("Flo (中文（中国大陆）)", "未检测到双击信号，继续下一步。");
    }

    let step3 = collect_button_step(
        &mut notif_stream,
        "long_press",
        "第三步，请在十五秒内，按住欧米按键一秒半后立刻松开，注意不要超过三秒以免关机。",
        22,
        2200,
    )
    .await;
    let _ = speak_via_mac_speaker(
        "Flo (中文（中国大陆）)",
        "物理按键交互测试全部完成，感谢配合，现在继续修复安卓端并完成最终测试。",
    );

    let report = json!({
        "generatedAtEpochSec": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
        "mode": "button-interactive",
        "deviceId": target.id,
        "deviceName": target.name,
        "initialReadHex": initial_read,
        "steps": [step1, step2, step3],
    });
    let out_path = evidence_dir.join("phase5_button_interactive.json");
    std::fs::write(&out_path, serde_json::to_string_pretty(&report)?)?;
    eprintln!("[button] 证据已写入 {}", out_path.display());

    drop(notif_stream);
    let _ = tokio::time::timeout(Duration::from_secs(3), peripheral.disconnect()).await;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("");
    let evidence_dir = args
        .get(2)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/omi_ble_evidence"));

    if mode != "gatt-and-realtime" && mode != "storage-ring" && mode != "button-interactive" {
        eprintln!(
            "用法: omi_ble_e2e_probe <gatt-and-realtime|storage-ring|button-interactive> <evidence_dir>"
        );
        std::process::exit(2);
    }

    let manager = Manager::new().await?;
    let adapters = manager.adapters().await?;
    let adapter = adapters.into_iter().next().ok_or("未找到可用 BLE 适配器")?;

    match mode {
        "gatt-and-realtime" => mode_gatt_and_realtime(&adapter, &evidence_dir).await?,
        "storage-ring" => mode_storage_ring(&adapter, &evidence_dir).await?,
        "button-interactive" => mode_button_interactive(&adapter, &evidence_dir).await?,
        _ => unreachable!(),
    }
    Ok(())
}
