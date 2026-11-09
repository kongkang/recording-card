mod ap_ready_tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn wifi_open_does_not_finish_before_actual_ap_ready_event() {
        let t = FakeTransport::new();
        t.record_pushes.store(false, Ordering::SeqCst);
        let mut session = fake_session(t.clone()).await;
        let started = tokio::time::Instant::now();
        let request = json!({"enabled":true});
        let enable = execute(&mut session, "setWifiEnabled", &request, discard, 701);
        let event = async {
            while !t.commands.lock().unwrap().iter().any(|c| c == "WIFI_OPEN") {
                tokio::task::yield_now().await;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
            t.send("WIFI_AP_START", json!({"code":0,"message":"AP ready"}));
        };
        let (result, _) = tokio::join!(enable, event);
        assert!(result.is_ok());
        assert!(started.elapsed() >= Duration::from_secs(2));
        assert!(device(&session).unwrap().access_point_ready());
        assert!(!t.source_deleted.load(Ordering::SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn wifi_power_ack_without_ap_ready_is_not_ready_success() {
        let t = FakeTransport::new();
        t.record_pushes.store(false, Ordering::SeqCst);
        let mut session = fake_session(t.clone()).await;
        let error = execute(
            &mut session,
            "setWifiEnabled",
            &json!({"enabled":true}),
            discard,
            702,
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, "ap_not_ready");
        assert!(!device(&session).unwrap().access_point_ready());
        assert!(!t.source_deleted.load(Ordering::SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn already_powered_wifi_preserves_sdk_reconnect_contract() {
        let t = FakeTransport::new();
        t.record_pushes.store(false, Ordering::SeqCst);
        t.wifi.store(true, Ordering::SeqCst);
        let mut session = fake_session(t.clone()).await;
        execute(
            &mut session,
            "setWifiEnabled",
            &json!({"enabled":true}),
            discard,
            703,
        )
        .await
        .unwrap();
        assert!(!t.commands.lock().unwrap().iter().any(|c| c == "WIFI_OPEN"));
        assert!(device(&session).unwrap().access_point_ready());
        assert!(!t.source_deleted.load(Ordering::SeqCst));
    }
}
