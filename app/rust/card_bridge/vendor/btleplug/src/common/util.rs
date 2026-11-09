// btleplug Source Code File
//
// Copyright 2020 Nonpolynomial. All rights reserved.
//
// Licensed under the BSD 3-Clause license. See LICENSE file in the project root
// for full license information.

use crate::api::ValueNotification;
use futures::stream::{Stream, StreamExt};
use std::pin::Pin;
use tokio::sync::broadcast::Receiver;
use tokio_stream::wrappers::BroadcastStream;

pub fn notifications_stream_from_broadcast_receiver(
    receiver: Receiver<ValueNotification>,
) -> Pin<Box<dyn Stream<Item = ValueNotification> + Send>> {
    Box::pin(BroadcastStream::new(receiver).filter_map(|x| async move { x.ok() }))
}

// Power of two, so Tokio does not round this capacity up. This bounds retained
// notification entries, not the downstream SDK inbox or arbitrary Vec sizes.
#[cfg(target_vendor = "apple")]
pub(crate) const APPLE_NOTIFICATION_CAPACITY: usize = 1024;

/// Keep the loss count visible and never resume with the surviving suffix.
/// The original infallible API is retained for unmodified upstream callers.
#[cfg(target_vendor = "apple")]
pub(crate) fn try_notifications_stream_from_broadcast_receiver(
    receiver: Receiver<ValueNotification>,
) -> Pin<Box<dyn Stream<Item = crate::Result<ValueNotification>> + Send>> {
    counted_notifications_stream_from_broadcast_receiver(receiver, None)
}

#[cfg(target_vendor = "apple")]
pub(crate) fn counted_notifications_stream_from_broadcast_receiver(
    receiver: Receiver<ValueNotification>,
    counters: Option<
        std::sync::Arc<crate::corebluetooth::notification_diagnostics::NotificationDiagnostics>,
    >,
) -> Pin<Box<dyn Stream<Item = crate::Result<ValueNotification>> + Send>> {
    use crate::corebluetooth::notification_diagnostics::ReceiverCounters;
    use std::sync::atomic::Ordering::Relaxed;
    Box::pin(
        futures::stream::unfold((receiver, false, ReceiverCounters::new(counters)), |(mut receiver, failed, counters)| async move {
            if failed {
                return None;
            }
            match receiver.recv().await {
                Ok(notification) => Some((Ok(notification), (receiver, false, counters))),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(lost)) => {
                    if let Some(counters) = &counters.0 {
                        counters.consumer_lag_events.fetch_add(1, Relaxed);
                        counters.consumer_lag_notifications.fetch_add(lost, Relaxed);
                    }
                    Some((
                        Err(crate::Error::RuntimeError(format!(
                            "BLE notification stream lagged: lost {lost} notifications; stream invalid"
                        ))),
                        (receiver, true, counters),
                    ))
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    if let Some(counters) = &counters.0 {
                        counters.consumer_closed.fetch_add(1, Relaxed);
                    }
                    None
                }
            }
        })
        .fuse(),
    )
}

#[cfg(all(test, target_vendor = "apple"))]
mod notification_tests {
    use super::*;
    use tokio::sync::broadcast;
    use uuid::Uuid;

    // Synthetic sequence markers only; never uses an adapter or audio.
    fn packet(sequence: usize) -> ValueNotification {
        let mut value = vec![0; 201];
        value[1..9].copy_from_slice(&(sequence as u64).to_le_bytes());
        ValueNotification {
            uuid: Uuid::nil(),
            service_uuid: Uuid::nil(),
            value,
        }
    }
    fn sequence(packet: &ValueNotification) -> usize {
        u64::from_le_bytes(packet.value[1..9].try_into().unwrap()) as usize
    }

    #[tokio::test]
    async fn original_16_entry_window_reports_six_lost_packets() {
        let (tx, mut rx) = broadcast::channel(16);
        for n in 0..22 {
            tx.send(packet(n)).unwrap();
        }
        assert!(matches!(
            rx.try_recv(),
            Err(broadcast::error::TryRecvError::Lagged(6))
        ));
        let mut retained = Vec::new();
        while let Ok(notification) = rx.try_recv() {
            retained.push(sequence(&notification));
        }
        assert_eq!(retained, (6..22).collect::<Vec<_>>());
        assert_eq!(6 * (packet(0).value.len() - 1), 1200);
    }

    #[tokio::test]
    async fn original_converter_hides_lag_and_returns_ordered_suffix() {
        let (tx, rx) = broadcast::channel(16);
        let stream = notifications_stream_from_broadcast_receiver(rx);
        for n in 0..22 {
            tx.send(packet(n)).unwrap();
        }
        drop(tx);
        let retained = stream.map(|p| sequence(&p)).collect::<Vec<_>>().await;
        assert_eq!(retained, (6..22).collect::<Vec<_>>());
    }

    #[tokio::test]
    async fn expanded_window_retains_a_full_burst_in_order() {
        let (tx, rx) = broadcast::channel(APPLE_NOTIFICATION_CAPACITY);
        let mut stream = try_notifications_stream_from_broadcast_receiver(rx);
        for n in 0..APPLE_NOTIFICATION_CAPACITY {
            tx.send(packet(n)).unwrap();
        }
        drop(tx);
        for n in 0..APPLE_NOTIFICATION_CAPACITY {
            assert_eq!(sequence(&stream.next().await.unwrap().unwrap()), n);
        }
        assert!(stream.next().await.is_none());
    }

    #[tokio::test]
    async fn expanded_window_overflow_reports_count_once_then_stays_closed() {
        let (tx, rx) = broadcast::channel(APPLE_NOTIFICATION_CAPACITY);
        let mut stream = try_notifications_stream_from_broadcast_receiver(rx);
        for n in 0..APPLE_NOTIFICATION_CAPACITY + 6 {
            tx.send(packet(n)).unwrap();
        }
        let error = stream.next().await.unwrap().unwrap_err();
        assert!(error.to_string().contains("lost 6 notifications"));
        // Keep the producer alive: EOF is a sticky failure, not sender closure.
        assert!(stream.next().await.is_none());
        let _ = tx.send(packet(9999));
        assert!(stream.next().await.is_none());
    }

    #[tokio::test]
    async fn lag_after_a_valid_prefix_does_not_deliver_a_suffix() {
        let (tx, rx) = broadcast::channel(APPLE_NOTIFICATION_CAPACITY);
        let mut stream = try_notifications_stream_from_broadcast_receiver(rx);
        tx.send(packet(0)).unwrap();
        assert_eq!(sequence(&stream.next().await.unwrap().unwrap()), 0);
        // Register a waiting receiver, then simulate a scheduler-stalled burst.
        assert!(futures::poll!(stream.next()).is_pending());
        for n in 1..=APPLE_NOTIFICATION_CAPACITY + 6 {
            tx.send(packet(n)).unwrap();
        }
        assert!(
            stream
                .next()
                .await
                .unwrap()
                .unwrap_err()
                .to_string()
                .contains("lost 6 notifications")
        );
        assert!(stream.next().await.is_none());
    }

    #[tokio::test]
    async fn closed_sender_without_notifications_is_eof() {
        let (tx, rx) = broadcast::channel(APPLE_NOTIFICATION_CAPACITY);
        let mut stream = try_notifications_stream_from_broadcast_receiver(rx);
        drop(tx);
        assert!(stream.next().await.is_none());
    }

    #[tokio::test]
    async fn counted_receiver_lag_remains_fail_closed_and_drop_is_measured() {
        use crate::corebluetooth::notification_diagnostics::NotificationDiagnostics;
        let counters = std::sync::Arc::new(NotificationDiagnostics::default());
        let (tx, rx) = broadcast::channel(16);
        let mut stream =
            counted_notifications_stream_from_broadcast_receiver(rx, Some(counters.clone()));
        for n in 0..22 {
            tx.send(packet(n)).unwrap();
        }
        assert!(
            stream
                .next()
                .await
                .unwrap()
                .unwrap_err()
                .to_string()
                .contains("lost 6 notifications")
        );
        assert!(stream.next().await.is_none());
        drop(stream);
        let snapshot = counters.snapshot();
        let value = |key| snapshot.iter().find(|(name, _)| name == key).unwrap().1;
        assert_eq!(value("consumer_lag_events"), 1);
        assert_eq!(value("consumer_lag_notifications"), 6);
        assert_eq!(value("consumer_closed"), 0);
        assert_eq!(value("receivers_started"), 1);
        assert_eq!(value("receivers_dropped"), 1);
    }

    #[tokio::test]
    async fn counted_receiver_closed_is_distinct_from_lag() {
        use crate::corebluetooth::notification_diagnostics::NotificationDiagnostics;
        let counters = std::sync::Arc::new(NotificationDiagnostics::default());
        let (tx, rx) = broadcast::channel(16);
        let mut stream =
            counted_notifications_stream_from_broadcast_receiver(rx, Some(counters.clone()));
        drop(tx);
        assert!(stream.next().await.is_none());
        drop(stream);
        let snapshot = counters.snapshot();
        let value = |key| snapshot.iter().find(|(name, _)| name == key).unwrap().1;
        assert_eq!(value("consumer_lag_events"), 0);
        assert_eq!(value("consumer_closed"), 1);
        assert_eq!(value("receivers_dropped"), 1);
    }
}
