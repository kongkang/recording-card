mod safe_tests {
    use super::*;
    use crate::safe_transfer::validate_epoch;
    use std::{
        pin::Pin,
        task::{Context, Poll},
    };
    use tokio::io::AsyncWrite;

    fn clean_transport() -> Arc<FakeTransport> {
        let t = FakeTransport::new();
        t.record_pushes.store(false, Ordering::SeqCst);
        *t.file_entries.lock().unwrap() = Some(vec![
            entry("a.apm", 3, "AABBCCDD", 1),
            entry("a.txt", 3, "AABBCCDD", 1),
            entry("a.mrk", 3, "AABBCCDD", 1),
        ]);
        t
    }
    fn entry(name: &str, size: u64, session: &str, seq: u32) -> Value {
        json!({"index":0,"name":name,"size":size,"is_dir":0,"session":session,"seq":seq,"start_at":100,"created_at":120,"synced":true})
    }
    fn frame(command: &str, payload: Value) -> UploadAction {
        UploadAction::Frame(format!("{command}:{payload}\r\n").into_bytes())
    }
    fn start(size: u64) -> UploadAction {
        frame(
            "FILE_UPLOAD",
            json!({"code":0,"state":"start","size":size,"name":"a.apm"}),
        )
    }
    fn end() -> UploadAction {
        frame("FILE_UPLOAD", json!({"code":0,"state":"end"}))
    }
    fn options(absolute: u64, idle: u64) -> reai_card_sdk::KeepTransferOptions {
        let mut options = reai_card_sdk::KeepTransferOptions::for_size(3);
        options.absolute_timeout = Duration::from_secs(absolute);
        options.idle_timeout = Duration::from_secs(idle);
        options
    }
    fn no_delete(t: &FakeTransport) {
        assert!(!t.source_deleted.load(Ordering::SeqCst));
        assert!(!t
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|cmd| cmd == "FILE_DELETE" || cmd == "FILE_CLEAR"));
        for (cmd, payload) in t.payloads.lock().unwrap().iter() {
            if cmd == "FILE_UPLOAD" {
                assert_eq!(payload["keep"], true);
            }
        }
        assert_eq!(t.notifications_count.load(Ordering::SeqCst), 1);
    }
    async fn sdk_download(
        t: Arc<FakeTransport>,
        opts: reai_card_sdk::KeepTransferOptions,
    ) -> (
        reai_card_sdk::Result<reai_card_sdk::TakenFile>,
        Vec<u8>,
        DyjDevice,
    ) {
        let d = DyjDevice::from_transport(t).await.unwrap();
        let (_cancel, rx) = tokio::sync::watch::channel(false);
        let mut output = Vec::new();
        let result = d
            .download_file_preserving_to("a.apm", &mut output, opts, rx, |_, _| {})
            .await;
        (result, output, d)
    }
    fn unique_dir(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "card-safe-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
    fn request(dir: &std::path::Path, name: &str) -> Value {
        json!({"name":name,"directory":dir,"expectedDeviceId":"fake-card","expectedBytes":3,"transport":"ble"})
    }
    fn confirm(receipt: &Value) -> Value {
        json!({"downloadId":receipt["downloadId"],"repositoryCommitted":true,"expectedDeviceId":receipt["deviceId"],"sha256":receipt["sha256"]})
    }
    #[tokio::test]
    async fn binary_start_end_uses_keep_and_one_stream_and_preserves_source() {
        let t = clean_transport();
        *t.upload_script.lock().unwrap() = Some(vec![
            UploadAction::Frame(vec![0, 99]),
            start(3),
            UploadAction::Frame(vec![0, 1]),
            frame("BATTERY", json!({"level":50})),
            UploadAction::Frame(vec![0, 2, 3]),
            end(),
        ]);
        let (result, output, d) = sdk_download(t.clone(), options(10, 2)).await;
        assert_eq!(result.unwrap().bytes_written, 3);
        assert_eq!(output, [1, 2, 3]);
        assert!(!d.is_terminal());
        no_delete(&t);
    }
    #[tokio::test]
    async fn raw_command_cannot_steal_file_end_from_shared_command_gate() {
        let t = clean_transport();
        *t.upload_script.lock().unwrap() = Some(vec![
            start(3),
            UploadAction::Delay(Duration::from_millis(50)),
            UploadAction::Frame(vec![0, 1, 2, 3]),
            end(),
        ]);
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let (_cancel, rx) = tokio::sync::watch::channel(false);
        let mut output = Vec::new();
        let transfer =
            d.download_file_preserving_to("a.apm", &mut output, options(10, 2), rx, |_, _| {});
        let raw = async {
            while !t
                .commands
                .lock()
                .unwrap()
                .iter()
                .any(|c| c == "FILE_UPLOAD")
            {
                tokio::task::yield_now().await;
            }
            d.raw_command("BATTERY", None).await
        };
        let (file, battery) = tokio::join!(transfer, raw);
        assert_eq!(file.unwrap().bytes_written, 3);
        assert_eq!(battery.unwrap()["level"], 52);
        no_delete(&t);
    }
    #[tokio::test]
    async fn old_or_unknown_firmware_refuses_keep_before_upload() {
        for code in [0, 308] {
            let t = clean_transport();
            t.replies.lock().unwrap().insert("BASE_INFO".into(),json!({"version":"old","versionCode":code,"deviceId":"fake-card","deviceName":"DYJV2_FAKE","timestamp":1}));
            let (result, output, _) = sdk_download(t.clone(), options(10, 2)).await;
            assert!(result.is_err());
            assert!(output.is_empty());
            assert!(!t
                .commands
                .lock()
                .unwrap()
                .iter()
                .any(|cmd| cmd == "FILE_UPLOAD"));
            no_delete(&t);
        }
        let t = clean_transport();
        t.replies.lock().unwrap().insert(
            "BASE_INFO".into(),
            json!({"version":"unknown","deviceId":"fake-card"}),
        );
        let (result, _, _) = sdk_download(t.clone(), options(10, 2)).await;
        assert!(result.is_err());
        no_delete(&t);
    }
    #[tokio::test(start_paused = true)]
    async fn unrelated_notifications_do_not_extend_idle_deadline() {
        let t = clean_transport();
        let mut script = vec![start(3)];
        for _ in 0..10 {
            script.push(UploadAction::Delay(Duration::from_millis(400)));
            script.push(frame("BATTERY", json!({"level":20})));
        }
        *t.upload_script.lock().unwrap() = Some(script);
        let (result, _, d) = sdk_download(t.clone(), options(10, 1)).await;
        assert!(matches!(result,Err(SdkError::Timeout{command,..}) if command.contains("idle")));
        assert!(d.is_terminal());
        no_delete(&t);
    }
    #[tokio::test(start_paused = true)]
    async fn useful_data_cannot_extend_absolute_deadline() {
        let t = clean_transport();
        *t.upload_script.lock().unwrap() = Some(vec![
            start(3),
            UploadAction::Delay(Duration::from_millis(700)),
            UploadAction::Frame(vec![0, 1]),
            UploadAction::Delay(Duration::from_millis(700)),
            UploadAction::Frame(vec![0, 2]),
            end(),
        ]);
        let (result, _, d) = sdk_download(t.clone(), options(1, 2)).await;
        assert!(
            matches!(result,Err(SdkError::Timeout{command,..}) if command.contains("absolute"))
        );
        assert!(d.is_terminal());
        no_delete(&t);
    }
    #[tokio::test]
    async fn short_overflow_missing_start_duplicate_start_and_disconnect_never_delete() {
        for script in [
            vec![start(3), UploadAction::Frame(vec![0, 1]), end()],
            vec![start(3), UploadAction::Frame(vec![0, 1, 2, 3, 4]), end()],
            vec![end()],
            vec![start(3), start(3)],
            vec![start(3), UploadAction::Terminal],
            vec![start(2)],
        ] {
            let t = clean_transport();
            *t.upload_script.lock().unwrap() = Some(script);
            let (result, _, d) = sdk_download(t.clone(), options(10, 2)).await;
            assert!(result.is_err());
            assert!(d.is_terminal());
            no_delete(&t);
        }
    }
    #[tokio::test]
    async fn hardware_record_start_during_file_stream_invalidates_copy() {
        let t = clean_transport();
        *t.upload_script.lock().unwrap() = Some(vec![
            start(3),
            frame(
                "RECORD_STATUS",
                json!({"isRecording":true,"realtimeEnabled":false,"reason":"button","session":"11223344"}),
            ),
            UploadAction::Frame(vec![0, 1, 2, 3]),
            end(),
        ]);
        let (result, _, d) = sdk_download(t.clone(), options(10, 2)).await;
        assert!(result.is_err());
        assert!(d.is_terminal());
        no_delete(&t);
    }
    #[tokio::test(start_paused = true)]
    async fn cooperative_cancel_poison_closes_inflight_stream_and_retains_source() {
        let t = clean_transport();
        *t.upload_script.lock().unwrap() = Some(vec![
            start(3),
            UploadAction::Delay(Duration::from_secs(50)),
            end(),
        ]);
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let (cancel, rx) = tokio::sync::watch::channel(false);
        let mut output = Vec::new();
        let signal = async {
            tokio::time::sleep(Duration::from_millis(150)).await;
            cancel.send_replace(true);
        };
        let (result, _) = tokio::join!(
            d.download_file_preserving_to("a.apm", &mut output, options(10, 2), rx, |_, _| {}),
            signal
        );
        assert!(result.is_err());
        assert!(d.is_terminal());
        no_delete(&t);
    }
    struct PendingWriter;
    impl AsyncWrite for PendingWriter {
        fn poll_write(
            self: Pin<&mut Self>,
            _: &mut Context<'_>,
            _: &[u8],
        ) -> Poll<std::io::Result<usize>> {
            Poll::Pending
        }
        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Pending
        }
        fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }
    #[tokio::test(start_paused = true)]
    async fn stalled_writer_obeys_absolute_timeout_and_dropped_future_poison_guard() {
        let t = clean_transport();
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let (_cancel, rx) = tokio::sync::watch::channel(false);
        let result = d
            .download_file_preserving_to("a.apm", &mut PendingWriter, options(1, 2), rx, |_, _| {})
            .await;
        assert!(matches!(result, Err(SdkError::Timeout { .. })));
        assert!(d.is_terminal());
        no_delete(&t);
        let t = clean_transport();
        *t.upload_script.lock().unwrap() = Some(vec![
            start(3),
            UploadAction::Delay(Duration::from_secs(50)),
            end(),
        ]);
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let (_cancel, rx) = tokio::sync::watch::channel(false);
        let mut output = Vec::new();
        let result = tokio::time::timeout(
            Duration::from_millis(200),
            d.download_file_preserving_to("a.apm", &mut output, options(10, 2), rx, |_, _| {}),
        )
        .await;
        assert!(result.is_err());
        assert!(d.is_terminal());
        no_delete(&t);
    }
    #[tokio::test]
    async fn native_audio_and_all_sidecars_have_synced_hash_receipts_but_no_atomic_delete() {
        let dir = unique_dir("sidecars");
        let t = clean_transport();
        let mut session = fake_session(t.clone()).await;
        for (n, name) in ["a.apm", "a.txt", "a.mrk"].into_iter().enumerate() {
            let receipt = download_preserving(&mut session, &request(&dir, name), discard, 100 + n)
                .await
                .unwrap();
            assert_eq!(receipt["sourceDeleted"], false);
            assert_eq!(receipt["remoteGeneration"]["session"], "AABBCCDD");
            assert_eq!(
                hash_local(Path::new(receipt["path"].as_str().unwrap()), 3)
                    .await
                    .unwrap(),
                receipt["sha256"].as_str().unwrap()
            );
            assert!(
                Path::new(receipt["path"].as_str().unwrap())
                    .extension()
                    .unwrap()
                    == name.rsplit('.').next().unwrap()
            );
            let error = confirm_delete(&mut session, &confirm(&receipt))
                .await
                .unwrap_err();
            assert_eq!(error.code, "source_retained");
            // Repeated confirmation must never issue a filename delete.
            assert_eq!(
                confirm_delete(&mut session, &confirm(&receipt))
                    .await
                    .unwrap_err()
                    .code,
                "source_retained"
            );
        }
        no_delete(&t);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    use std::path::Path;
    #[tokio::test]
    async fn changed_remote_generation_refuses_old_receipt_even_same_name_and_size() {
        let dir = unique_dir("generation");
        let t = clean_transport();
        let mut session = fake_session(t.clone()).await;
        let receipt = download_preserving(&mut session, &request(&dir, "a.apm"), discard, 200)
            .await
            .unwrap();
        *t.file_entries.lock().unwrap() = Some(vec![entry("a.apm", 3, "11223344", 2)]);
        let error = confirm_delete(&mut session, &confirm(&receipt))
            .await
            .unwrap_err();
        assert_eq!(error.code, "source_retained");
        assert!(error.message.contains("代际"));
        no_delete(&t);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[tokio::test]
    async fn vanished_remote_still_keeps_complete_local_bytes_but_grants_no_source_authority() {
        // Real-device finding: after a complete BLE keep transfer the card's own
        // FILE_LIST no longer returns the entry. Bytes already received, synced
        // and hashed must survive as local data; only the *delete authority*
        // may be withheld. Dropping the file would lose a recording that the
        // phone demonstrably received in full.
        let dir = unique_dir("vanished");
        let t = clean_transport();
        let mut session = fake_session(t.clone()).await;
        // Preflight must see the entry; it is the post-transfer re-list that
        // comes back empty, which is exactly what the device did.
        let entries = t.file_entries.clone();
        t.upload_script.lock().unwrap().get_or_insert_with(|| {
            vec![
                UploadAction::Frame(vec![0, 99]),
                start(3),
                UploadAction::Frame(vec![0, 1]),
                UploadAction::Frame(vec![0, 2]),
                UploadAction::Frame(vec![0, 3]),
                end(),
            ]
        });
        t.vanish_after_upload.store(true, Ordering::SeqCst);
        let receipt = download_preserving(&mut session, &request(&dir, "a.apm"), discard, 210)
            .await
            .unwrap();
        let _ = entries;
        assert_eq!(receipt["bytes"], 3);
        assert_eq!(receipt["sourceDeleted"], false);
        assert_eq!(receipt["sourceRetained"], true);
        assert_eq!(receipt["generationConfirmed"], false);
        // The preflight generation is still reported for diagnostics, but the
        // receipt must carry no delete authority (see the confirm below).
        assert_eq!(receipt["remoteGeneration"]["session"], "AABBCCDD");
        let path = Path::new(receipt["path"].as_str().unwrap());
        assert_eq!(hash_local(path, 3).await.unwrap(), receipt["sha256"]);
        // No delete authorization: confirmation must refuse, and it must refuse
        // because the generation is unknown rather than silently succeeding.
        let error = confirm_delete(&mut session, &confirm(&receipt))
            .await
            .unwrap_err();
        assert_eq!(error.code, "source_retained");
        no_delete(&t);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[tokio::test]
    async fn ap_sd_epoch_changes_and_record_mutations_invalidate_old_receipts() {        let dir = unique_dir("epoch");
        let t = clean_transport();
        let mut session = fake_session(t.clone()).await;
        let receipt = download_preserving(&mut session, &request(&dir, "a.apm"), discard, 300)
            .await
            .unwrap();
        let stored = session.receipts[receipt["downloadId"].as_str().unwrap()].clone();
        // Bind an AP receipt to a continuous epoch too; opening/closing is not
        // treated as proof of the original AP ownership after it comes back.
        let mut ap_receipt = stored.clone();
        ap_receipt.ap = true;
        assert!(validate_epoch(
            &ap_receipt,
            ap_receipt.local_epoch + 1,
            ap_receipt.source_epoch
        )
        .is_err());
        t.send("WIFI_OFF", json!({"code":0}));
        tokio::task::yield_now().await;
        assert_eq!(
            confirm_delete(&mut session, &confirm(&receipt))
                .await
                .unwrap_err()
                .code,
            "source_retained"
        );
        let previous = session.receipt_epoch;
        let _ = execute(
            &mut session,
            "setRecording",
            &json!({"enabled":false}),
            discard,
            301,
        )
        .await
        .unwrap();
        assert!(session.receipt_epoch > previous);
        no_delete(&t);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[tokio::test]
    async fn capability_requires_fresh_read_not_a_request_claim_and_terminal_event_is_immediate() {
        assert_eq!(
            crate::safe_transfer::capabilities(&Session::default())
                .await
                .unwrap()["safeBleDownload"],
            false
        );
        let t = clean_transport();
        let session = fake_session(t.clone()).await;
        assert_eq!(
            crate::safe_transfer::capabilities(&session).await.unwrap()["safeBleDownload"],
            true
        );
        let d = device(&session).unwrap();
        let mut events = d.subscribe_events();
        t.tx.send(Err(SdkError::Disconnected)).unwrap();
        loop {
            if matches!(events.recv().await.unwrap(), DeviceEvent::Disconnected) {
                break;
            }
        }
        assert!(d.is_terminal());
        assert_eq!(
            d.raw_command("BATTERY", None)
                .await
                .unwrap_err()
                .to_string(),
            SdkError::Disconnected.to_string()
        );
        no_delete(&t);
    }
    #[tokio::test]
    async fn committed_and_hash_identity_guards_and_deleted_tombstone_are_idempotent() {
        let dir = unique_dir("tombstone");
        let t = clean_transport();
        let mut session = fake_session(t.clone()).await;
        let receipt = download_preserving(&mut session, &request(&dir, "a.apm"), discard, 400)
            .await
            .unwrap();
        let mut req = confirm(&receipt);
        req["repositoryCommitted"] = json!(false);
        assert_eq!(
            confirm_delete(&mut session, &req).await.unwrap_err().code,
            "confirmation"
        );
        req = confirm(&receipt);
        req["sha256"] = json!("wrong");
        assert_eq!(
            confirm_delete(&mut session, &req).await.unwrap_err().code,
            "identity"
        );
        // Synthetic authoritative tombstone tests only the repeat-confirm path.
        // No production code sets deleted=true with current filename-only SDK.
        session
            .receipts
            .get_mut(receipt["downloadId"].as_str().unwrap())
            .unwrap()
            .deleted = true;
        let count = t.commands.lock().unwrap().len();
        for _ in 0..2 {
            assert_eq!(
                confirm_delete(&mut session, &confirm(&receipt))
                    .await
                    .unwrap()["alreadyDeleted"],
                true
            );
        }
        assert_eq!(count, t.commands.lock().unwrap().len());
        no_delete(&t);
        close_connection(&mut session).await.unwrap();
        assert_eq!(
            confirm_delete(&mut session, &confirm(&receipt))
                .await
                .unwrap_err()
                .code,
            "receipt"
        );
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[tokio::test]
    async fn native_cancel_signal_bypasses_lane_and_failed_copy_has_no_receipt() {
        let dir = unique_dir("native-cancel");
        let t = clean_transport();
        *t.upload_script.lock().unwrap() = Some(vec![
            start(3),
            UploadAction::Delay(Duration::from_secs(50)),
            end(),
        ]);
        let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
        let copy = run_in_lane(
            {
                let mut req = request(&dir, "a.apm");
                req["op"] = json!("downloadFilePreservingSource");
                req
            },
            discard,
            500,
            &lane,
        );
        let cancellation = async {
            while !t
                .commands
                .lock()
                .unwrap()
                .iter()
                .any(|cmd| cmd == "FILE_UPLOAD")
            {
                tokio::task::yield_now().await;
            }
            run(
                json!({"op":"cancelFileTransfer","transferTicket":500}),
                discard,
                501,
            )
            .await
            .unwrap()
        };
        let (copy, cancel) = tokio::join!(copy, cancellation);
        assert_eq!(cancel["cancelSignalled"], true);
        assert_eq!(copy.unwrap_err().code, "cancelled");
        assert!(lane.lock().await.receipts.is_empty());
        no_delete(&t);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[tokio::test(start_paused = true)]
    async fn real_ap_receipt_rejects_wifi_cycle_and_record_attempt_before_http_access() {
        for (op, enabled) in [
            ("setWifiEnabled", false),
            ("setRecording", true),
            ("setRealtimeEnabled", true),
        ] {
            let dir = unique_dir("ap-continuity");
            tokio::fs::create_dir_all(&dir).await.unwrap();
            let path = dir.join("a.apm");
            tokio::fs::write(&path, [1u8, 2, 3]).await.unwrap();
            let digest = hash_local(&path, 3).await.unwrap();
            let t = clean_transport();
            t.wifi.store(true, Ordering::SeqCst);
            let mut session = fake_session(t.clone()).await;
            let source_epoch = device(&session).unwrap().source_epoch();
            session.receipts.insert(
                "ap".into(),
                DownloadReceipt {
                    name: "a.apm".into(),
                    device_id: "fake-card".into(),
                    transport_id: "fake-transport".into(),
                    path,
                    bytes: 3,
                    sha256: digest.clone(),
                    ap: true,
                    local_epoch: session.receipt_epoch,
                    source_epoch,
                    generation: None,
                    deleted: false,
                },
            );
            let _ = execute(&mut session, op, &json!({"enabled":enabled}), discard, 601).await;
            if op == "setWifiEnabled" {
                let _ = execute(&mut session, op, &json!({"enabled":true}), discard, 602).await;
            }
            let count = t.commands.lock().unwrap().len();
            let error=confirm_delete(&mut session,&json!({"downloadId":"ap","repositoryCommitted":true,"expectedDeviceId":"fake-card","sha256":digest})).await.unwrap_err();
            assert_eq!(error.code, "source_retained");
            assert!(error.message.contains("epoch"));
            assert_eq!(
                count,
                t.commands.lock().unwrap().len(),
                "stale AP receipt must reject before AP/HTTP operation"
            );
            no_delete(&t);
            tokio::fs::remove_dir_all(dir).await.unwrap();
        }
    }
    #[tokio::test]
    async fn notification_eof_emits_terminal_without_waiting_for_next_command() {
        let t = clean_transport();
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let mut events = d.subscribe_events();
        t.tx.send(Ok(Vec::new())).unwrap(); // Fake stream EOF marker, no real transport.
        assert!(matches!(
            events.recv().await.unwrap(),
            DeviceEvent::Disconnected
        ));
        assert!(d.is_terminal());
        no_delete(&t);
    }
    #[tokio::test(start_paused = true)]
    async fn native_cancel_during_preflight_never_starts_upload_and_cleans_session() {
        let dir = unique_dir("preflight-cancel");
        let t = clean_transport();
        t.silent.lock().unwrap().push("BASE_INFO".into());
        let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
        let copy = run_in_lane(
            {
                let mut req = request(&dir, "a.apm");
                req["op"] = json!("downloadFilePreservingSource");
                req
            },
            discard,
            700,
            &lane,
        );
        let cancel = async {
            while !t
                .commands
                .lock()
                .unwrap()
                .iter()
                .any(|cmd| cmd == "BASE_INFO")
            {
                tokio::task::yield_now().await;
            }
            run(
                json!({"op":"cancelFileTransfer","transferTicket":700}),
                discard,
                701,
            )
            .await
            .unwrap()
        };
        let (copy, cancel) = tokio::join!(copy, cancel);
        assert_eq!(cancel["data"], Value::Null); // run returns data directly, no FFI envelope.
        assert_eq!(cancel["cancelSignalled"], true);
        assert_eq!(copy.unwrap_err().code, "cancelled");
        assert!(!t
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|cmd| cmd == "FILE_UPLOAD"));
        assert!(lane.lock().await.connection.is_none());
        no_delete(&t);
    }
    #[test]
    fn four_c_abi_symbols_keep_their_signatures() {
        let _: extern "C" fn() -> *const c_char = card_bridge_version;
        let _: unsafe extern "C" fn(*const c_char, Callback, usize) = card_bridge_request;
        let _: unsafe extern "C" fn(*mut c_char) = card_bridge_free_string;
        let _: extern "C" fn(Option<Callback>) = card_bridge_set_event_callback;
    }
    include!("safe_transfer_cleanup_tests.rs");
}
