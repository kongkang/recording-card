// Included inside safe_tests: exercises the real vendor parser/worker, no adapter.
#[tokio::test(start_paused = true)]
async fn guard_cleanup_is_single_owned_and_native_recovery_blocks_late_disconnect() {
    let t = clean_transport();
    let block = TestBlock::new();
    *t.disconnect_block.lock().unwrap() = Some(block.clone());
    *t.upload_script.lock().unwrap() = Some(vec![start(3), UploadAction::Frame(vec![0, 1]), end()]);
    let dir = unique_dir("cleanup-barrier");
    let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
    let mut req = request(&dir, "a.apm");
    req["op"] = json!("downloadFilePreservingSource");
    let result = run_in_lane(req, discard, 8100, &lane).await;
    assert!(result.is_err());
    block.reached().await;
    assert_eq!(t.disconnect_count.load(Ordering::SeqCst), 1);
    {
        let session = lane.lock().await;
        assert!(session.connection.is_none());
        assert!(session.receipts.is_empty());
        assert!(!session.recovery.as_ref().unwrap().is_finished());
    }
    // This must stop BEFORE DeviceManager/scan is ever entered.
    let reconnect = run_in_lane(
        json!({"op":"connect","id":"fake-transport"}),
        discard,
        8101,
        &lane,
    )
    .await
    .unwrap_err();
    assert_eq!(reconnect.code, "busy");
    assert!(!t.disconnected.load(Ordering::SeqCst));
    block.release.add_permits(1);
    let recovery = lane.lock().await.recovery.take().unwrap();
    recovery.await.unwrap();
    assert!(t.disconnected.load(Ordering::SeqCst));
    // Install a fresh fake connection only AFTER the shared old job completed.
    let fresh = clean_transport();
    *lane.lock().await = fake_session(fresh.clone()).await;
    assert_eq!(
        device(&*lane.lock().await)
            .unwrap()
            .battery()
            .await
            .unwrap()
            .level,
        52
    );
    tokio::time::advance(Duration::from_secs(60)).await;
    assert_eq!(t.disconnect_count.load(Ordering::SeqCst), 1);
    assert!(!fresh.disconnected.load(Ordering::SeqCst));
    no_delete(&t);
    no_delete(&fresh);
    tokio::fs::remove_dir_all(dir).await.unwrap();
}

struct ObservedWriter {
    polled: Arc<tokio::sync::Semaphore>,
    fail_write: bool,
    fail_flush: bool,
}
impl AsyncWrite for ObservedWriter {
    fn poll_write(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        self.polled.add_permits(1);
        if self.fail_write {
            Poll::Ready(Err(std::io::Error::other("controlled write failure")))
        } else if self.fail_flush {
            Poll::Ready(Ok(bytes.len()))
        } else {
            Poll::Pending
        }
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        if self.fail_flush {
            Poll::Ready(Err(std::io::Error::other("controlled flush failure")))
        } else {
            Poll::Pending
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}
#[tokio::test(start_paused = true)]
async fn blocked_writer_observes_terminal_idle_and_cancel_without_absolute_wait() {
    for mode in ["terminal", "idle", "cancel"] {
        let t = clean_transport();
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let (cancel, rx) = tokio::sync::watch::channel(false);
        let polled = Arc::new(tokio::sync::Semaphore::new(0));
        let mut writer = ObservedWriter {
            polled: polled.clone(),
            fail_write: false,
            fail_flush: false,
        };
        let began = tokio::time::Instant::now();
        let signal = async {
            polled.acquire().await.unwrap().forget();
            match mode {
                "terminal" => {
                    t.tx.send(Err(SdkError::Disconnected)).unwrap();
                }
                "cancel" => {
                    cancel.send_replace(true);
                }
                _ => {}
            }
        };
        let (result, _) = tokio::join!(
            d.download_file_preserving_to("a.apm", &mut writer, options(100, 1), rx, |_, _| {}),
            signal
        );
        match mode {
            "terminal" => assert!(matches!(result, Err(SdkError::Disconnected))),
            "idle" => assert!(
                matches!(result, Err(SdkError::Timeout { command, .. }) if command.contains("idle"))
            ),
            _ => assert!(matches!(result, Err(SdkError::InvalidCommand(_)))),
        }
        assert!(began.elapsed() < Duration::from_secs(2));
        assert!(d.is_terminal());
        no_delete(&t);
    }
}
#[tokio::test]
async fn controlled_sdk_write_and_flush_errors_never_report_completion() {
    for fail_flush in [false, true] {
        let t = clean_transport();
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let (_cancel, rx) = tokio::sync::watch::channel(false);
        let mut writer = ObservedWriter {
            polled: Arc::new(tokio::sync::Semaphore::new(0)),
            fail_write: !fail_flush,
            fail_flush,
        };
        assert!(d
            .download_file_preserving_to("a.apm", &mut writer, options(10, 2), rx, |_, _| {})
            .await
            .is_err());
        assert!(d.is_terminal());
        no_delete(&t);
    }
}
#[tokio::test(start_paused = true)]
async fn blocked_upload_command_observes_terminal_idle_and_cancel() {
    for mode in ["terminal", "idle", "cancel"] {
        let t = clean_transport();
        let block = TestBlock::new();
        *t.block_upload_write.lock().unwrap() = Some(block.clone());
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let (cancel, rx) = tokio::sync::watch::channel(false);
        let signal = async {
            block.reached().await;
            match mode {
                "terminal" => {
                    t.tx.send(Err(SdkError::Disconnected)).unwrap();
                }
                "cancel" => {
                    cancel.send_replace(true);
                }
                _ => {}
            }
        };
        let mut output = Vec::new();
        let began = tokio::time::Instant::now();
        let (result, _) = tokio::join!(
            d.download_file_preserving_to("a.apm", &mut output, options(100, 1), rx, |_, _| {}),
            signal
        );
        assert!(result.is_err());
        assert!(began.elapsed() < Duration::from_secs(2));
        assert!(output.is_empty());
        assert!(!t
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|c| c == "FILE_UPLOAD"));
        no_delete(&t);
    }
}
#[tokio::test(start_paused = true)]
async fn command_gate_contention_after_preflight_observes_cancel_idle_absolute_and_terminal() {
    for mode in ["cancel", "idle", "absolute", "terminal"] {
        let t = clean_transport();
        let state_block = TestBlock::new();
        let raw_block = TestBlock::new();
        t.write_blocks
            .lock()
            .unwrap()
            .insert("STATE_INFO".into(), state_block.clone());
        t.write_blocks
            .lock()
            .unwrap()
            .insert("BATTERY".into(), raw_block.clone());
        let d = DyjDevice::from_transport(t.clone()).await.unwrap();
        let (cancel, rx) = tokio::sync::watch::channel(false);
        let opts = if mode == "absolute" {
            options(1, 10)
        } else {
            options(100, 1)
        };
        let control = async {
            state_block.reached().await;
            let raw = d.raw_command("BATTERY", None);
            tokio::pin!(raw);
            // Deterministically queue this request on the held gate before
            // releasing STATE_INFO. Tokio FIFO gives it the next ownership.
            assert!(futures::poll!(&mut raw).is_pending());
            state_block.release.add_permits(1);
            tokio::select! {
                _ = raw_block.reached() => {},
                _ = &mut raw => panic!("raw request should hold the gate"),
            }
            match mode {
                "cancel" => {
                    cancel.send_replace(true);
                }
                "terminal" => {
                    t.tx.send(Err(SdkError::Disconnected)).unwrap();
                }
                _ => {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
            }
            // Keep must finish while this competing request still owns the gate.
            tokio::time::sleep(Duration::from_millis(1)).await;
            raw_block.release.add_permits(1);
            let _ = raw.await;
        };
        let mut output = Vec::new();
        let (result, _) = tokio::join!(
            d.download_file_preserving_to("a.apm", &mut output, opts, rx, |_, _| {}),
            control
        );
        match mode {
            "cancel" => assert!(matches!(result, Err(SdkError::InvalidCommand(_)))),
            "terminal" => assert!(matches!(result, Err(SdkError::Disconnected))),
            _ => assert!(
                matches!(result, Err(SdkError::Timeout { command, .. }) if command.contains(mode))
            ),
        }
        assert!(output.is_empty());
        assert!(!t
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|c| c == "FILE_UPLOAD"));
        no_delete(&t);
    }
}
#[tokio::test]
async fn mutation_between_record_preflight_and_upload_cannot_be_absorbed() {
    let t = clean_transport();
    let block = TestBlock::new();
    t.write_blocks
        .lock()
        .unwrap()
        .insert("STATE_INFO".into(), block.clone());
    let d = DyjDevice::from_transport(t.clone()).await.unwrap();
    let old = d.source_epoch();
    let (_cancel, rx) = tokio::sync::watch::channel(false);
    let mutate = async {
        block.reached().await; // RECORD_STATUS reply was already consumed.
        t.send(
            "RECORD_STATUS",
            json!({"isRecording":true,"realtimeEnabled":false,"reason":"button"}),
        );
        while d.source_epoch() == old {
            tokio::task::yield_now().await;
        }
        block.release.add_permits(1);
    };
    let mut output = Vec::new();
    let (result, _) = tokio::join!(
        d.download_file_preserving_to("a.apm", &mut output, options(10, 2), rx, |_, _| {}),
        mutate
    );
    assert!(matches!(result, Err(SdkError::Protocol(message)) if message.contains("preflight")));
    assert!(output.is_empty());
    assert!(!t
        .commands
        .lock()
        .unwrap()
        .iter()
        .any(|c| c == "FILE_UPLOAD"));
    no_delete(&t);
}
#[tokio::test]
async fn queued_transaction_can_be_cancelled_without_touching_device_or_receipt() {
    let t = clean_transport();
    let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
    let held = lane.lock().await;
    let before = t.commands.lock().unwrap().len();
    let mut req = request(&unique_dir("queued-cancel"), "a.apm");
    req["op"] = json!("downloadFilePreservingSource");
    let copy = run_in_lane(req, discard, 8200, &lane);
    tokio::pin!(copy);
    assert!(futures::poll!(&mut copy).is_pending());
    let cancel = run(
        json!({"op":"cancelFileTransfer","transferTicket":8200}),
        discard,
        8201,
    )
    .await
    .unwrap();
    assert_eq!(cancel["cancelSignalled"], true);
    assert_eq!(copy.await.unwrap_err().code, "cancelled");
    assert_eq!(before, t.commands.lock().unwrap().len());
    assert!(held.receipts.is_empty());
    assert!(!t.disconnected.load(Ordering::SeqCst));
    assert_eq!(
        run(
            json!({"op":"cancelFileTransfer","transferTicket":8200}),
            discard,
            8202
        )
        .await
        .unwrap()["cancelSignalled"],
        false
    );
    no_delete(&t);
}
#[test]
fn cancellation_before_registration_is_conservative_and_never_claims_completion() {
    let req = json!({"transferTicket":8300});
    assert_eq!(
        crate::safe_transfer::cancel_transfer(&req).unwrap()["cancelSignalled"],
        false
    );
    let registration = crate::safe_transfer::register_transfer(8300).unwrap();
    assert!(!*registration.cancelled.borrow());
    let signal = crate::safe_transfer::cancel_transfer(&req).unwrap();
    assert_eq!(signal["cancelSignalled"], true);
    assert_eq!(signal["sourceDeleted"], false);
    assert_eq!(signal["completed"], Value::Null);
    assert!(*registration.cancelled.borrow());
    assert!(crate::safe_transfer::register_transfer(8300).is_err());
    drop(registration);
    assert_eq!(
        crate::safe_transfer::cancel_transfer(&req).unwrap()["cancelSignalled"],
        false
    );
}
#[tokio::test]
async fn native_short_stream_and_unwritable_destination_have_zero_receipts() {
    for disk_failure in [false, true] {
        let t = clean_transport();
        let dir = unique_dir("failed-receipt");
        if disk_failure {
            tokio::fs::write(&dir, b"not a directory").await.unwrap();
        } else {
            *t.upload_script.lock().unwrap() =
                Some(vec![start(3), UploadAction::Frame(vec![0, 1]), end()]);
        }
        let mut session = fake_session(t.clone()).await;
        assert!(download_preserving(
            &mut session,
            &request(&dir, "a.apm"),
            discard,
            if disk_failure { 8400 } else { 8401 }
        )
        .await
        .is_err());
        assert!(session.receipts.is_empty());
        no_delete(&t);
        if disk_failure {
            tokio::fs::remove_file(dir).await.unwrap();
        } else {
            tokio::fs::remove_dir_all(dir).await.unwrap();
        }
    }
}

#[tokio::test]
async fn native_durability_failures_and_cancel_at_receipt_never_sign_completion() {
    for (n, stage) in [
        "flush",
        "sync",
        "rename",
        "directory_sync",
        "cancel_at_receipt",
    ]
    .into_iter()
    .enumerate()
    {
        let t = clean_transport();
        let dir = unique_dir(stage);
        let mut session = fake_session(t.clone()).await;
        session.transfer_io_fault = Some(stage); // Test-only I/O fault, absent in production build.
        let error = download_preserving(&mut session, &request(&dir, "a.apm"), discard, 8500 + n)
            .await
            .unwrap_err();
        assert_eq!(
            error.code,
            if stage == "cancel_at_receipt" {
                "cancelled"
            } else {
                "io"
            }
        );
        assert!(session.receipts.is_empty());
        assert!(t
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|c| c == "FILE_UPLOAD"));
        let mut entries = tokio::fs::read_dir(&dir).await.unwrap();
        let owned = entries.next_entry().await.unwrap().unwrap().path();
        assert!(entries.next_entry().await.unwrap().is_none());
        let mut files = tokio::fs::read_dir(owned).await.unwrap();
        let copy = files.next_entry().await.unwrap().unwrap().path();
        assert_eq!(tokio::fs::read(&copy).await.unwrap(), [1, 2, 3]);
        assert_eq!(
            copy.file_name().unwrap() == "download.part",
            matches!(stage, "flush" | "sync" | "rename")
        );
        no_delete(&t);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
}
#[tokio::test]
async fn native_terminal_during_blocked_postcheck_returns_without_receipt() {
    let t = clean_transport();
    *t.upload_script.lock().unwrap() = Some(vec![
        start(3),
        UploadAction::Delay(Duration::from_millis(50)),
        UploadAction::Frame(vec![0, 1, 2, 3]),
        end(),
    ]);
    let block = TestBlock::new();
    let dir = unique_dir("terminal-postcheck");
    let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
    let mut req = request(&dir, "a.apm");
    req["op"] = json!("downloadFilePreservingSource");
    let control = async {
        while !t
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|c| c == "FILE_UPLOAD")
        {
            tokio::task::yield_now().await;
        }
        t.write_blocks
            .lock()
            .unwrap()
            .insert("FILE_LIST".into(), block.clone());
        block.reached().await; // Post-download metadata query is blocked in write.
        t.tx.send(Err(SdkError::Disconnected)).unwrap();
    };
    let (result, _) = tokio::join!(run_in_lane(req, discard, 8600, &lane), control);
    assert_eq!(result.unwrap_err().code, "disconnected");
    let session = lane.lock().await;
    assert!(session.connection.is_none());
    assert!(session.receipts.is_empty());
    no_delete(&t);
    tokio::fs::remove_dir_all(dir).await.unwrap();
}
