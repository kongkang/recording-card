// Test-only deterministic bytes: never used by production or real hardware.
use super::*;
use reai_card_sdk::{KeepTransferOptions, KeepTransferStats, SdkNotificationCounters};
use sha2::{Digest, Sha256};
use std::{
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::AsyncWrite;

const FULL_PACKETS: usize = 10_931;
const FULL_BYTES: u64 = 2_186_240;
const SHORT_BYTES: u64 = 2_183_440;

fn clean() -> Arc<FakeTransport> {
    let t = FakeTransport::new();
    t.record_pushes.store(false, Ordering::SeqCst);
    *t.file_entries.lock().unwrap() = Some(vec![json!({
        "index":0,"name":"a.apm","size":FULL_BYTES,"is_dir":0,
        "session":"AABBCCDD","seq":1,"start_at":100,"created_at":120,"synced":true
    })]);
    t
}
fn text(payload: Value) -> UploadAction {
    UploadAction::Frame(format!("FILE_UPLOAD:{payload}\r\n").into_bytes())
}
fn start(size: u64) -> UploadAction {
    text(json!({"code":0,"state":"start","size":size,"name":"a.apm"}))
}
fn end() -> UploadAction {
    text(json!({"code":0,"state":"end"}))
}
fn packet(payload: &[u8]) -> UploadAction {
    let mut bytes = Vec::with_capacity(payload.len() + 1);
    bytes.push(0);
    bytes.extend_from_slice(payload);
    UploadAction::Frame(bytes)
}
fn fixture(omit_fourteen: bool) -> (Vec<UploadAction>, Vec<u8>) {
    let mut script = vec![start(FULL_BYTES)];
    let mut expected = Vec::with_capacity(FULL_BYTES as usize);
    for index in 0..=FULL_PACKETS {
        let size = if index == FULL_PACKETS { 40 } else { 200 };
        let mut payload: Vec<u8> = (0..size)
            .map(|offset| ((index * 31 + offset * 17) % 256) as u8)
            .collect();
        // Embedded protocol-looking data is binary and must never be decoded.
        let literal = b"\r\n{\"state\":\"end\"}\0FILE_UPLOAD:\r\n";
        payload[..literal.len()].copy_from_slice(literal);
        // Explicitly UNSENT test notifications, not simulated SDK loss.
        if omit_fourteen && (500..514).contains(&index) {
            continue;
        }
        expected.extend_from_slice(&payload);
        script.push(packet(&payload));
    }
    script.push(end());
    (script, expected)
}
fn no_delete(t: &FakeTransport) {
    assert!(!t.source_deleted.load(Ordering::SeqCst));
    assert!(!t.commands.lock().unwrap().iter().any(|cmd| matches!(
        cmd.as_str(),
        "FILE_DELETE" | "FILE_CLEAR" | "OTA_START" | "OTA_WIFI_START"
    )));
    for (command, payload) in t.payloads.lock().unwrap().iter() {
        if command == "FILE_UPLOAD" {
            assert_eq!(payload["keep"], true);
        }
    }
    assert_eq!(t.notifications_count.load(Ordering::SeqCst), 1);
}
async fn collect(
    d: &DyjDevice,
    size: u64,
) -> (
    reai_card_sdk::Result<reai_card_sdk::TakenFile>,
    Vec<u8>,
    KeepTransferStats,
) {
    let mut bytes = Vec::new();
    let mut stats = KeepTransferStats::default();
    let (_cancel, rx) = tokio::sync::watch::channel(false);
    let result = d
        .download_file_preserving_with_stats_to(
            "a.apm",
            &mut bytes,
            KeepTransferOptions::for_size(size),
            rx,
            |_, _| {},
            &mut stats,
        )
        .await;
    (result, bytes, stats)
}
fn window(stats: &KeepTransferStats) -> SdkNotificationCounters {
    stats
        .sdk_end
        .unwrap()
        .saturating_delta_since(&stats.sdk_start.unwrap())
}
fn assert_scale(stats: &KeepTransferStats, bytes: u64, full_packets: u64) {
    assert_eq!(stats.pre_start_bytes, 0);
    assert_eq!(stats.pre_start_packets, 0);
    assert_eq!(stats.received_packets, full_packets + 1);
    assert_eq!(stats.last_packet_bytes, 40);
    assert_eq!(stats.start_size, Some(FULL_BYTES));
    assert!(stats.end_seen);
    let delta = window(stats);
    assert_eq!(delta.raw_packets, full_packets + 2); // data + end notification
    assert_eq!(delta.leading_zero_packets, full_packets + 1);
    assert_eq!(delta.leading_zero_payload_bytes, bytes);
    assert_eq!(delta.leading_zero_raw_bytes, bytes + full_packets + 1);
    assert_eq!(delta.payload_200_packets, full_packets);
    assert_eq!(delta.payload_40_packets, 1);
    assert_eq!(delta.payload_other_packets, 0);
    assert_eq!(delta.payload_zero_packets, 0);
    assert_eq!(delta.binary_enqueue_ok_packets, full_packets + 1);
    assert_eq!(delta.binary_enqueue_ok_bytes, bytes);
    assert_eq!(delta.binary_enqueue_failed_packets, 0);
    assert_eq!(delta.inactive_audio_packets, 0);
    assert_eq!(delta.parser_faults, 0);
    assert_eq!(delta.upload_end_frames, 1);
    // Fake/non-Apple default means unknown, not invented measured zero.
    assert!(stats.transport_begin.is_none());
    assert!(stats.transport_end.is_none());
}

#[tokio::test]
async fn full_2186240_bytes_10932_packets_match_bytes_hash_and_worker_prefix() {
    let t = clean();
    let (script, expected) = fixture(false);
    assert_eq!(expected.len() as u64, FULL_BYTES);
    *t.upload_script.lock().unwrap() = Some(script);
    let d = DyjDevice::from_transport(t.clone()).await.unwrap();
    let (result, output, stats) = collect(&d, FULL_BYTES).await;
    assert_eq!(result.unwrap().bytes_written, FULL_BYTES);
    assert_eq!(output, expected);
    assert_eq!(Sha256::digest(&output), Sha256::digest(&expected));
    assert_scale(&stats, FULL_BYTES, FULL_PACKETS as u64);
    no_delete(&t);
}

#[tokio::test]
async fn explicitly_unsent_fourteen_packets_remain_short_10918_and_fail() {
    let t = clean();
    let (script, expected) = fixture(true);
    assert_eq!(expected.len() as u64, SHORT_BYTES);
    *t.upload_script.lock().unwrap() = Some(script);
    let d = DyjDevice::from_transport(t.clone()).await.unwrap();
    let (result, output, stats) = collect(&d, FULL_BYTES).await;
    assert!(matches!(
        result,
        Err(SdkError::FileLengthMismatch {
            expected: FULL_BYTES,
            actual: SHORT_BYTES
        })
    ));
    assert_eq!(output, expected);
    assert_scale(&stats, SHORT_BYTES, FULL_PACKETS as u64 - 14);
    assert!(d.is_terminal());
    no_delete(&t);
}

#[tokio::test]
async fn native_scale_short_has_zero_receipts_and_preserves_fake_source() {
    let t = clean();
    let (script, _) = fixture(true);
    *t.upload_script.lock().unwrap() = Some(script);
    let mut session = fake_session(t.clone()).await;
    let dir = std::env::temp_dir().join(format!(
        "ble-sdk-count-short-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let result = download_preserving(
        &mut session,
        &json!({
            "name":"a.apm", "directory":dir, "expectedDeviceId":"fake-card",
            "expectedBytes":FULL_BYTES, "transport":"ble"
        }),
        discard,
        91001,
    )
    .await;
    assert!(result.is_err());
    assert!(session.receipts.is_empty());
    no_delete(&t);
    tokio::fs::remove_dir_all(dir).await.unwrap();
}

#[tokio::test]
async fn classification_keeps_nonzero_raw_zero_length_and_prestart_separate() {
    let t = clean();
    let mut nonzero = b"BATTERY:{\"level\":50}".to_vec();
    nonzero.resize(198, b' ');
    nonzero.extend_from_slice(b"\r\n");
    *t.upload_script.lock().unwrap() = Some(vec![
        packet(&[9; 200]),
        start(3),
        packet(&[1]),
        UploadAction::Frame(nonzero),
        UploadAction::Frame(b"{\"type\":\"test\"}\r\n".to_vec()),
        packet(&[]),
        packet(&[2, 3]),
        end(),
    ]);
    let d = DyjDevice::from_transport(t.clone()).await.unwrap();
    let (result, output, stats) = collect(&d, 3).await;
    assert_eq!(result.unwrap().bytes_written, 3);
    assert_eq!(output, [1, 2, 3]);
    assert_eq!(stats.pre_start_bytes, 200);
    assert_eq!(stats.pre_start_packets, 1);
    assert_eq!(stats.received_packets, 3);
    let all = stats
        .sdk_end
        .unwrap()
        .saturating_delta_since(&stats.sdk_begin.unwrap());
    assert_eq!(all.leading_zero_payload_bytes, 203);
    assert_eq!(all.payload_200_packets, 1);
    assert_eq!(all.payload_other_packets, 2);
    assert_eq!(all.payload_zero_packets, 1);
    assert_eq!(all.nonzero_text_packets, 4); // start, BATTERY, raw, end
    assert_eq!(all.raw_frames, 1);
    assert_eq!(all.parser_faults, 0);
    assert_eq!(window(&stats).leading_zero_payload_bytes, 3);
    no_delete(&t);
}

// Block ONLY test writer's first poll so worker can get ahead of keep. Every
// successful write afterwards deliberately returns partial slices.
struct GateWriter {
    gate: Arc<AtomicBool>,
    first: bool,
    output: Vec<u8>,
    polls: usize,
}
impl AsyncWrite for GateWriter {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        self.polls += 1;
        if self.first && !self.gate.load(Ordering::SeqCst) {
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        self.first = false;
        let size = bytes.len().min(37);
        self.output.extend_from_slice(&bytes[..size]);
        Poll::Ready(Ok(size))
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}
async fn gate_collect(
    t: Arc<FakeTransport>,
    size: u64,
    expected_packets: u64,
) -> (
    reai_card_sdk::Result<reai_card_sdk::TakenFile>,
    GateWriter,
    KeepTransferStats,
    DyjDevice,
) {
    let d = DyjDevice::from_transport(t).await.unwrap();
    let baseline = d.sdk_notification_counters().raw_packets;
    let gate = Arc::new(AtomicBool::new(false));
    let mut writer = GateWriter {
        gate: gate.clone(),
        first: true,
        output: Vec::new(),
        polls: 0,
    };
    let mut stats = KeepTransferStats::default();
    let (_cancel, rx) = tokio::sync::watch::channel(false);
    let control = async {
        tokio::time::timeout(Duration::from_secs(10), async {
            // 3 preflight responses plus scripted notifications, no new stream.
            while d.sdk_notification_counters().raw_packets < baseline + 3 + expected_packets {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        gate.store(true, Ordering::SeqCst);
    };
    let (result, _) = tokio::join!(
        d.download_file_preserving_with_stats_to(
            "a.apm",
            &mut writer,
            KeepTransferOptions::for_size(size),
            rx,
            |_, _| {},
            &mut stats
        ),
        control
    );
    (result, writer, stats, d)
}

#[tokio::test]
async fn end_after_data_never_recovers_late_bytes_and_snapshot_is_fixed() {
    for size in [3, 5] {
        let t = clean();
        let mut script = vec![start(size), packet(&[1, 2, 3]), end()];
        script.extend((0..14).map(|_| packet(&[8; 200])));
        *t.upload_script.lock().unwrap() = Some(script);
        let (result, writer, stats, d) = gate_collect(t.clone(), size, 17).await;
        if size == 3 {
            assert_eq!(result.unwrap().bytes_written, 3);
        } else {
            assert!(matches!(
                result,
                Err(SdkError::FileLengthMismatch {
                    expected: 5,
                    actual: 3
                })
            ));
        }
        assert_eq!(writer.output, [1, 2, 3]);
        assert_eq!(stats.received_packets, 1);
        assert_eq!(window(&stats).leading_zero_payload_bytes, 3);
        let after = d
            .sdk_notification_counters()
            .saturating_delta_since(&stats.sdk_end.unwrap());
        assert_eq!(after.leading_zero_packets, 14);
        assert_eq!(after.leading_zero_payload_bytes, 2800);
        assert_eq!(after.binary_enqueue_ok_bytes, 2800);
        no_delete(&t);
    }
}

#[tokio::test]
async fn end_and_fault_same_notification_preserve_existing_acceptance_boundary() {
    for size in [3, 5] {
        let t = clean();
        let mut combined =
            format!("FILE_UPLOAD:{}\r\n", json!({"code":0,"state":"end"})).into_bytes();
        combined.extend_from_slice(b"BROKEN:{]\r\n");
        *t.upload_script.lock().unwrap() = Some(vec![
            start(size),
            packet(&[1, 2, 3]),
            UploadAction::Frame(combined),
        ]);
        let (result, writer, stats, d) = gate_collect(t.clone(), size, 3).await;
        if size == 3 {
            assert_eq!(result.unwrap().bytes_written, 3);
        } else {
            assert!(matches!(
                result,
                Err(SdkError::FileLengthMismatch {
                    expected: 5,
                    actual: 3
                })
            ));
        }
        assert_eq!(writer.output, [1, 2, 3]);
        assert_eq!(stats.sdk_end.unwrap().parser_faults, 0);
        assert_eq!(d.sdk_notification_counters().parser_faults, 1);
        assert_eq!(window(&stats).leading_zero_payload_bytes, 3);
        no_delete(&t);
    }
}

#[tokio::test]
async fn slow_partial_writer_keeps_full_scale_bytes_hash_and_prefix() {
    let t = clean();
    let (script, expected) = fixture(false);
    *t.upload_script.lock().unwrap() = Some(script);
    let (result, writer, stats, _) =
        gate_collect(t.clone(), FULL_BYTES, (FULL_PACKETS + 3) as u64).await;
    assert_eq!(result.unwrap().bytes_written, FULL_BYTES);
    assert_eq!(writer.output, expected);
    assert_eq!(Sha256::digest(&writer.output), Sha256::digest(&expected));
    assert!(writer.polls > FULL_PACKETS * 5);
    assert_scale(&stats, FULL_BYTES, FULL_PACKETS as u64);
    no_delete(&t);
}

#[tokio::test]
async fn connection_counters_do_not_reset_across_audio_or_second_keep() {
    let t = clean();
    *t.upload_script.lock().unwrap() = Some(vec![start(3), packet(&[1, 2, 3]), end()]);
    let d = DyjDevice::from_transport(t.clone()).await.unwrap();
    t.tx.send(Ok(vec![0, 9, 9])).unwrap();
    tokio::time::timeout(Duration::from_secs(2), async {
        while d.sdk_notification_counters().inactive_audio_packets == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let (one, _, first) = collect(&d, 3).await;
    one.unwrap();
    let fixed_first = first.sdk_end.unwrap();
    let (two, _, second) = collect(&d, 3).await;
    two.unwrap();
    assert!(second.sdk_begin.unwrap().raw_packets >= fixed_first.raw_packets);
    assert_eq!(second.sdk_end.unwrap().upload_end_frames, 2);
    assert_eq!(second.sdk_end.unwrap().inactive_audio_packets, 1);
    assert_eq!(window(&first).leading_zero_payload_bytes, 3);
    assert_eq!(window(&second).leading_zero_payload_bytes, 3);
    assert_eq!(first.sdk_end.unwrap(), fixed_first);
    no_delete(&t);
}
