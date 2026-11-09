//! Connection-lifetime integer diagnostics. No payload retention or reset.
use std::sync::atomic::{AtomicU64, Ordering};

// The worker is the only writer. A reader's live/begin snapshot is NOT fenced:
// fields can straddle one notification. A boundary snapshot made by that same
// worker is a fixed processed prefix (not a firmware send count). Raw ingress
// includes the entire notification, even if it contains end plus a later fault.
macro_rules! counters {
    ($($field:ident),+ $(,)?) => {
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
        pub struct SdkNotificationCounters {
            $(pub $field: u64,)+
        }
        impl SdkNotificationCounters {
            /// Saturating difference of connection cumulative snapshots. Begin
            /// is non-fenced; start/end snapshots are worker-ordered prefixes.
            pub fn saturating_delta_since(&self, earlier: &Self) -> Self {
                Self { $($field: self.$field.saturating_sub(earlier.$field),)+ }
            }
        }
        #[derive(Default)]
        pub(super) struct NotificationCounters {
            $(pub(super) $field: AtomicU64,)+
        }
        impl NotificationCounters {
            pub(super) fn snapshot(&self) -> SdkNotificationCounters {
                SdkNotificationCounters {
                    $($field: self.$field.load(Ordering::Relaxed),)+
                }
            }
        }
    };
}

counters!(
    raw_packets,
    raw_bytes,
    empty_packets,
    leading_zero_packets,
    leading_zero_raw_bytes,
    leading_zero_payload_bytes,
    payload_200_packets,
    payload_40_packets,
    payload_other_packets,
    payload_zero_packets,
    binary_enqueue_ok_packets,
    binary_enqueue_ok_bytes,
    binary_enqueue_failed_packets,
    binary_enqueue_failed_bytes,
    inactive_audio_packets,
    inactive_audio_bytes,
    nonzero_text_packets,
    nonzero_text_bytes,
    text_frames,
    raw_frames,
    parser_faults,
    transport_errors,
    upload_start_frames,
    upload_end_frames,
);

impl NotificationCounters {
    pub(super) fn observe_packet(&self, bytes: &[u8]) {
        self.raw_packets.fetch_add(1, Ordering::Relaxed);
        self.raw_bytes
            .fetch_add(bytes.len() as u64, Ordering::Relaxed);
        match bytes.first() {
            Some(0) => {
                let size = bytes.len() - 1;
                self.leading_zero_packets.fetch_add(1, Ordering::Relaxed);
                self.leading_zero_raw_bytes
                    .fetch_add(bytes.len() as u64, Ordering::Relaxed);
                self.leading_zero_payload_bytes
                    .fetch_add(size as u64, Ordering::Relaxed);
                let bucket = match size {
                    200 => &self.payload_200_packets,
                    40 => &self.payload_40_packets,
                    0 => &self.payload_zero_packets,
                    _ => &self.payload_other_packets,
                };
                bucket.fetch_add(1, Ordering::Relaxed);
            }
            Some(_) => {
                self.nonzero_text_packets.fetch_add(1, Ordering::Relaxed);
                self.nonzero_text_bytes
                    .fetch_add(bytes.len() as u64, Ordering::Relaxed);
            }
            None => {
                self.empty_packets.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
    pub(super) fn observe_binary_enqueue(&self, bytes: usize, ok: bool) {
        let (packets, size) = if ok {
            (
                &self.binary_enqueue_ok_packets,
                &self.binary_enqueue_ok_bytes,
            )
        } else {
            (
                &self.binary_enqueue_failed_packets,
                &self.binary_enqueue_failed_bytes,
            )
        };
        packets.fetch_add(1, Ordering::Relaxed);
        size.fetch_add(bytes as u64, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::super::spawn_notification_worker;
    use super::*;
    use std::sync::{Arc, atomic::AtomicBool};
    use tokio::sync::{broadcast, mpsc, watch};

    async fn run(active: bool, packets: Vec<crate::Result<Vec<u8>>>) -> SdkNotificationCounters {
        let counters = Arc::new(NotificationCounters::default());
        let (incoming, receiver) = mpsc::unbounded_channel();
        drop(receiver); // Exercise the ORIGINAL unbounded send failure.
        let (events, _) = broadcast::channel(1);
        let (audio, _) = broadcast::channel(1);
        let (ap, _) = watch::channel(false);
        let (terminal, mut ended) = watch::channel(false);
        spawn_notification_worker(
            Box::pin(futures::stream::iter(packets)),
            incoming,
            events,
            audio,
            Arc::new(AtomicBool::new(active)),
            Arc::new(ap),
            Arc::new(AtomicU64::new(0)),
            Arc::new(terminal),
            counters.clone(),
        );
        ended.wait_for(|value| *value).await.unwrap();
        counters.snapshot()
    }

    #[tokio::test]
    async fn closed_inbox_counts_failed_binary_without_changing_send_semantics() {
        let counts = run(
            true,
            vec![
                Ok(vec![0]),
                Ok(vec![0; 201]),
                Ok(vec![0; 41]),
                Ok(vec![0; 4]),
            ],
        )
        .await;
        assert_eq!(counts.raw_packets, 4);
        assert_eq!(counts.raw_bytes, 247);
        assert_eq!(counts.leading_zero_payload_bytes, 243);
        assert_eq!(counts.payload_zero_packets, 1);
        assert_eq!(counts.payload_200_packets, 1);
        assert_eq!(counts.payload_40_packets, 1);
        assert_eq!(counts.payload_other_packets, 1);
        assert_eq!(counts.binary_enqueue_failed_packets, 4);
        assert_eq!(counts.binary_enqueue_failed_bytes, 243);
        assert_eq!(counts.binary_enqueue_ok_packets, 0);
    }

    #[tokio::test]
    async fn inactive_empty_raw_fault_and_stream_error_are_independent() {
        let counts = run(
            false,
            vec![
                Ok(vec![]),
                Ok(vec![0, 1, 2]),
                Ok(b"{\"type\":\"test\"}\r\n".to_vec()),
                Ok(b"BAD:{]\r\n".to_vec()),
                Err(crate::SdkError::Disconnected),
            ],
        )
        .await;
        assert_eq!(counts.raw_packets, 4); // Errors are not made-up byte packets.
        assert_eq!(counts.empty_packets, 1);
        assert_eq!(counts.inactive_audio_packets, 1);
        assert_eq!(counts.inactive_audio_bytes, 2);
        assert_eq!(counts.binary_enqueue_failed_packets, 0);
        assert_eq!(counts.nonzero_text_packets, 2);
        assert_eq!(counts.raw_frames, 1);
        assert_eq!(counts.parser_faults, 1);
        assert_eq!(counts.transport_errors, 1);
    }
}
